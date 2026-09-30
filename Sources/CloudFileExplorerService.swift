import CmuxFileTree
import CmuxFileSearch
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
    func search(vmID: String, query: FileSearchQuery, rootPath: String, matchLimit: Int) async throws -> CloudFileSearchResult {
        let runner = commandRunner
        return try await searchQueue.submit {
            try await Self.performSearch(
                commandRunner: runner,
                vmID: vmID,
                query: query,
                rootPath: rootPath,
                matchLimit: matchLimit
            )
        }
    }

    /// The exec API returns stdout only when the command ends, so the guest
    /// filter keeps match lines only and stops ripgrep at a line or byte
    /// budget. Exit 75 means `rg` is not installed on the VM.
    private static func performSearch(
        commandRunner: any CloudFileExplorerCommandRunning,
        vmID: String,
        query: FileSearchQuery,
        rootPath: String,
        matchLimit: Int
    ) async throws -> CloudFileSearchResult {
        let lineLimit = min(matchLimit, maxSearchResults)
        let script = #"""
import subprocess, sys
limit = int(sys.argv[1])
byte_limit = \#(Self.maxPreviewBytes)
rg_args = sys.argv[2:]
try:
    process = subprocess.Popen(["rg", *rg_args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
    sys.stdout.buffer.write(b"__CMUX_LIMIT__\n")
    sys.stdout.buffer.flush()
    sys.exit(0)
exit_code = process.wait()
if exit_code not in (0, 1):
    sys.stderr.buffer.write(process.stderr.read()[-4096:])
sys.exit(0 if exit_code in (0, 1) else exit_code)
"""#
        let command = "python3 -c \(Self.shellQuote(script)) \(lineLimit) "
            + query.ripgrepArguments(rootPath: rootPath).map(Self.shellQuote).joined(separator: " ")
        let result = try await commandRunner.run(vmID: vmID, command: command, timeoutMs: 30_000)
        if result.exitCode == 75 {
            return CloudFileSearchResult(groups: [], completion: .failed(.ripgrepNotFound))
        }
        let decoder = RipgrepStreamDecoder(matchLimit: Int.max)
        var groups = decoder.consume(Array(result.stdout.utf8))
        groups.appendMerging(decoder.finish())
        let wasLimited = result.stdout.contains("__CMUX_LIMIT__")
        let completion = FileSearchCompletion(
            ripgrepExitStatus: Int32(truncatingIfNeeded: result.exitCode),
            standardError: result.stderr,
            matchCount: decoder.matchCount,
            limitReached: wasLimited,
            matchLimit: decoder.matchCount
        )
        return CloudFileSearchResult(groups: groups, completion: completion)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
