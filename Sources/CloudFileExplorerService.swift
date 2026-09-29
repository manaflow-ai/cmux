import CmuxFileTree
import Foundation

/// Runs bounded filesystem operations on one Cloud VM.
actor CloudFileExplorerService {
    private static let maxSearchResults = 500
    private static let maxPreviewBytes = 1_048_576
    private static let maxEntriesPerDirectory = 10_000
    private let commandRunner: any CloudFileExplorerCommandRunning
    private let searchQueue = CloudFileExplorerSearchQueue()

    /// Creates a service with the command transport used by one Cloud machine.
    init(commandRunner: any CloudFileExplorerCommandRunning) {
        self.commandRunner = commandRunner
    }

    /// Resolves the Cloud machine's home directory.
    func resolveHome(vmID: String) async throws -> String {
        let result = try await commandRunner.run(
            vmID: vmID,
            command: #"printf '%s\n' "$HOME""#,
            timeoutMs: 30_000
        )
        guard result.exitCode == 0 else { throw FileExplorerError.remoteCommandFailed("") }
        let home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { throw FileExplorerError.remoteCommandFailed("") }
        return home
    }

    /// Lists remote directories in one guest exec without crossing the local
    /// filesystem boundary. Each directory returns at most
    /// ``maxEntriesPerDirectory`` entries; the rest are counted as omitted so
    /// a huge `node_modules` shows a partial tree instead of an error.
    func listDirectories(vmID: String, paths: [String]) async throws -> [String: Result<FileTreeListing, any Error>] {
        guard !paths.isEmpty else { return [:] }
        let script = #"""
import json, os, stat, sys
limit = int(sys.argv[1])
results = []
for path in sys.argv[2:]:
    entries = []
    omitted = 0
    try:
        with os.scandir(path) as directory:
            for entry in directory:
                if len(entries) >= limit:
                    omitted += 1
                    continue
                kind = "f"
                size = None
                mtime = None
                try:
                    info = entry.stat(follow_symlinks=False)
                    mtime = info.st_mtime
                    if stat.S_ISDIR(info.st_mode):
                        kind = "d"
                    elif stat.S_ISLNK(info.st_mode):
                        kind = "L" if entry.is_dir(follow_symlinks=True) else "l"
                    elif stat.S_ISREG(info.st_mode):
                        size = info.st_size
                    else:
                        kind = "o"
                except OSError:
                    kind = "o"
                entries.append([entry.name, kind, size, mtime])
        results.append({"ok": True, "entries": entries, "omitted": omitted})
    except OSError as error:
        results.append({"ok": False, "error": error.strerror or "error"})
json.dump(results, sys.stdout, separators=(",", ":"))
"""#
        let quotedPaths = paths.map(Self.shellQuote).joined(separator: " ")
        let command = "python3 -c \(Self.shellQuote(script)) \(Self.maxEntriesPerDirectory) \(quotedPaths)"
        let result = try await commandRunner.run(vmID: vmID, command: command, timeoutMs: 30_000)
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let rawResults = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rawResults.count == paths.count else {
            throw FileExplorerError.remoteCommandFailed("")
        }
        var listings: [String: Result<FileTreeListing, any Error>] = [:]
        for (path, raw) in zip(paths, rawResults) {
            guard raw["ok"] as? Bool == true, let rawEntries = raw["entries"] as? [[Any]] else {
                listings[path] = .failure(FileExplorerError.remoteCommandFailed((raw["error"] as? String) ?? ""))
                continue
            }
            let parent = path.hasSuffix("/") ? path : path + "/"
            let entries = rawEntries.compactMap { fields -> FileTreeEntry? in
                guard fields.count == 4, let name = fields[0] as? String, let code = fields[1] as? String else { return nil }
                let kind: FileTreeEntryKind
                switch code {
                case "d": kind = .directory
                case "L": kind = .symbolicLinkToDirectory
                case "l": kind = .symbolicLink
                case "o": kind = .other
                default: kind = .file
                }
                return FileTreeEntry(
                    name: name,
                    path: parent + name,
                    kind: kind,
                    size: (fields[2] as? NSNumber)?.int64Value,
                    modificationTime: (fields[3] as? NSNumber)?.doubleValue
                )
            }
            listings[path] = .success(FileTreeListing(entries: entries, omittedCount: (raw["omitted"] as? Int) ?? 0))
        }
        return listings
    }

    /// Downloads one bounded remote file to a local preview cache.
    func download(vmID: String, path: String, to localURL: URL) async throws {
        let script = #"""
import base64, os, sys, stat as stat_module
path = sys.argv[1]
limit = int(sys.argv[2])
try:
    metadata = os.stat(path, follow_symlinks=True)
    if not stat_module.S_ISREG(metadata.st_mode):
        sys.exit(74)
    fd = os.open(path, os.O_RDONLY)
    try:
        stat = os.fstat(fd)
        if stat.st_size > limit:
            sys.exit(73)
        data = os.read(fd, limit + 1)
    finally:
        os.close(fd)
except OSError:
    sys.exit(74)
if len(data) > limit:
    sys.exit(73)
sys.stdout.write(base64.b64encode(data).decode("ascii"))
"""#
        let command = "python3 -c \(Self.shellQuote(script)) \(Self.shellQuote(path)) \(Self.maxPreviewBytes)"
        let result = try await commandRunner.run(vmID: vmID, command: command, timeoutMs: 30_000)
        if result.exitCode == 73 { throw FileExplorerError.remoteFileTooLarge }
        guard result.exitCode == 0,
              let data = Data(base64Encoded: result.stdout) else {
            throw FileExplorerError.remoteCommandFailed("")
        }
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: localURL, options: .atomic)
    }

    /// Keeps canceled HTTP callers from spawning overlapping guest scans.
    func search(vmID: String, query: String, rootPath: String) async throws -> FileSearchSnapshot {
        let runner = commandRunner
        return try await searchQueue.submit {
            try await Self.performSearch(commandRunner: runner, vmID: vmID, query: query, rootPath: rootPath)
        }
    }

    private static func performSearch(
        commandRunner: any CloudFileExplorerCommandRunning,
        vmID: String,
        query: String,
        rootPath: String
    ) async throws -> FileSearchSnapshot {
        let script = #"""
import subprocess, sys
limit = \#(Self.maxSearchResults)
byte_limit = \#(Self.maxPreviewBytes)
query = sys.argv[1]
root = sys.argv[2]
rg_args = sys.argv[3:]
try:
    process = subprocess.Popen(["rg", *rg_args, "--", query, root], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
except OSError:
    sys.exit(75)
count = 0
written = 0
limited = False
while True:
    line = process.stdout.readline(65537)
    if not line:
        break
    if not line.startswith(b'{"type":"match"'):
        continue
    if len(line) > 65536 or count >= limit or written + len(line) > byte_limit:
        limited = True
        break
    sys.stdout.buffer.write(line)
    count += 1
    written += len(line)
if limited:
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    sys.stdout.buffer.write(f"__CMUX_LIMIT__:{count}\n".encode())
    sys.stdout.buffer.flush()
    sys.exit(0)
exit_code = process.wait()
sys.exit(0 if exit_code in (0, 1) else exit_code)
"""#
        let rgArguments = [
            "--json", "--line-number", "--column", "--smart-case", "--fixed-strings",
            "--max-columns", "300", "--max-columns-preview", "--color", "never", "--hidden",
            "--glob", "!.git/**", "--glob", "!**/.git/**", "--glob", "!node_modules/**",
            "--glob", "!**/node_modules/**", "--glob", "!dist/**", "--glob", "!**/dist/**",
            "--glob", "!build/**", "--glob", "!**/build/**", "--glob", "!DerivedData/**",
            "--glob", "!**/DerivedData/**",
        ]
        let command = "python3 -c \(Self.shellQuote(script)) \(Self.shellQuote(query)) \(Self.shellQuote(rootPath)) "
            + rgArguments.map(Self.shellQuote).joined(separator: " ")
        let result = try await commandRunner.run(vmID: vmID, command: command, timeoutMs: 30_000)
        let limitCount = result.stdout
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("__CMUX_LIMIT__:") })
            .flatMap { Int($0.dropFirst("__CMUX_LIMIT__:".count)) }
        let results = result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { FileSearchRipgrepParser.parseMatchLine(String($0), rootPath: rootPath) }
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw FileExplorerError.remoteCommandFailed("")
        }
        return FileSearchSnapshot(
            query: query,
            results: results,
            status: results.isEmpty ? .noMatches : (limitCount.map { .limited($0) } ?? .matches),
            isSearching: false
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
