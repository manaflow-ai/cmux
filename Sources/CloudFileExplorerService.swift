import Foundation

/// Runs bounded filesystem operations on one Cloud VM.
actor CloudFileExplorerService {
    private static let maxSearchResults = 500
    private static let maxPreviewBytes = 1_048_576
    private let commandRunner: any CloudFileExplorerCommandRunning

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

    /// Lists one remote directory without crossing the local filesystem boundary.
    func listDirectory(vmID: String, path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        let script = #"""
import json, os, sys
path = sys.argv[1]
show_hidden = sys.argv[2] == "1"
entries = []
with os.scandir(path) as directory:
    for entry in directory:
        if not show_hidden and entry.name.startswith("."):
            continue
        entries.append({"name": entry.name, "path": entry.path, "directory": entry.is_dir(follow_symlinks=False)})
        if len(entries) > 10000:
            sys.exit(74)
json.dump(entries, sys.stdout, separators=(",", ":"))
"""#
        let command = "python3 -c \(Self.shellQuote(script)) \(Self.shellQuote(path)) \(showHidden ? "1" : "0")"
        let result = try await commandRunner.run(vmID: vmID, command: command, timeoutMs: 30_000)
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let rawEntries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FileExplorerError.remoteCommandFailed("")
        }
        return rawEntries.compactMap { raw in
            guard let name = raw["name"] as? String,
                  let entryPath = raw["path"] as? String,
                  let isDirectory = raw["directory"] as? Bool else { return nil }
            return FileExplorerEntry(name: name, path: entryPath, isDirectory: isDirectory)
        }
    }

    /// Downloads one bounded remote file to a local preview cache.
    func download(vmID: String, path: String, to localURL: URL) async throws {
        let script = #"""
import base64, os, sys
path = sys.argv[1]
limit = int(sys.argv[2])
try:
    fd = os.open(path, os.O_RDONLY)
    try:
        stat = os.fstat(fd)
        if not os.path.isfile(path) or stat.st_size > limit:
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
        let command = "python3 -c \(Self.shellQuote(script)) \(Self.shellQuote(path)) 1048576"
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

    /// Searches the remote root with a bounded ripgrep producer.
    func search(vmID: String, query: String, rootPath: String) async throws -> FileSearchSnapshot {
        let script = #"""
import subprocess, sys
limit = 500
byte_limit = 1048576
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
    sys.stdout.write("__CMUX_LIMIT__\n")
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
        let wasLimited = result.stdout.split(whereSeparator: \.isNewline).contains { $0 == "__CMUX_LIMIT__" }
        let results = result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { FileSearchRipgrepParser.parseMatchLine(String($0), rootPath: rootPath) }
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw FileExplorerError.remoteCommandFailed("")
        }
        return FileSearchSnapshot(
            query: query,
            results: results,
            status: results.isEmpty ? .noMatches : (wasLimited ? .limited(Self.maxSearchResults) : .matches),
            isSearching: false
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
