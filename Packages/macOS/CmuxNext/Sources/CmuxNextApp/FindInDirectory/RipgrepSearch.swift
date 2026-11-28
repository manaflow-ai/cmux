import Foundation

/// One ripgrep match: a line of a file under the searched directory.
nonisolated struct RipgrepMatch: Equatable, Sendable {
    let path: String
    let relativePath: String
    let line: Int
    let column: Int
    let preview: String
}

/// Find in Directory's search: `rg` over a local directory, run the way the
/// old app's file explorer ran it (fixed strings, smart case, hidden files,
/// VCS and build folders skipped), stopped after `limit` matches.
nonisolated enum RipgrepSearch {
    nonisolated enum Outcome: Equatable, Sendable {
        case matches([RipgrepMatch], limited: Bool)
        /// rg failed before finding anything (exit status 2: a bad path or
        /// an unreadable directory).
        case failed(status: Int32)
    }

    /// The old app's cap.
    static let limit = 500

    static let excludedGlobs = [
        "!.git/**", "!**/.git/**",
        "!node_modules/**", "!**/node_modules/**",
        "!dist/**", "!**/dist/**",
        "!build/**", "!**/build/**",
        "!DerivedData/**", "!**/DerivedData/**",
    ]

    /// `rg`: the usual install locations first (a Finder-launched app gets
    /// launchd's short PATH), then PATH.
    static func executable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userName: String = NSUserName(),
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let home = (home as NSString).standardizingPath
        let known = [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/opt/local/bin/rg",
            "/usr/bin/rg",
            "/etc/profiles/per-user/\(userName)/bin/rg",
            "/run/current-system/sw/bin/rg",
            "/nix/var/nix/profiles/default/bin/rg",
            "\(home)/.nix-profile/bin/rg",
            "/nix/var/nix/profiles/per-user/\(userName)/profile/bin/rg",
        ]
        let onPath = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/rg" }
        return (known + onPath).first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    static func arguments(query: String, root: String) -> [String] {
        ["--json", "--line-number", "--column", "--smart-case", "--fixed-strings",
         "--max-columns", "300", "--max-columns-preview", "--color", "never", "--hidden"]
            + excludedGlobs.flatMap { ["--glob", $0] }
            + ["--", query, root]
    }

    /// A `--json` output line, if it is a match.
    static func parse(_ line: String, root: String) -> RipgrepMatch? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "match",
              let payload = object["data"] as? [String: Any],
              let path = (payload["path"] as? [String: Any]).flatMap(text),
              let lines = (payload["lines"] as? [String: Any]).flatMap(text),
              let lineNumber = payload["line_number"] as? Int else { return nil }
        let start = (payload["submatches"] as? [[String: Any]])?.first?["start"] as? Int
        return RipgrepMatch(path: path, relativePath: relativePath(path, root: root), line: lineNumber,
                            column: (start ?? 0) + 1, preview: lines.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// rg writes non-UTF-8 text as base64 `bytes`.
    private static func text(_ object: [String: Any]) -> String? {
        if let text = object["text"] as? String { return text }
        guard let bytes = (object["bytes"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func relativePath(_ path: String, root: String) -> String {
        let root = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    /// Runs `rg`, off the main actor. Stops it at `limit` matches or when
    /// the caller is cancelled.
    @concurrent static func run(_ executable: URL, query: String, root: String, limit: Int = limit) async -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(query: query, root: root)
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { process in
            exited.continuation.yield(process.terminationStatus)
            exited.continuation.finish()
        }
        do {
            try process.run()
        } catch {
            return .failed(status: -1)
        }
        let running = RunningProcess(process)
        let (matches, limited) = await withTaskCancellationHandler {
            var matches: [RipgrepMatch] = []
            var line: [UInt8] = []
            // Split on "\n" only: `bytes.lines` also breaks at U+2028,
            // U+2029 and U+0085, which rg's JSON leaves unescaped.
            do {
                for try await byte in output.fileHandleForReading.bytes {
                    guard byte == UInt8(ascii: "\n") else {
                        line.append(byte)
                        continue
                    }
                    defer { line.removeAll(keepingCapacity: true) }
                    guard let match = parse(String(decoding: line, as: UTF8.self), root: root) else { continue }
                    matches.append(match)
                    if matches.count >= limit { return (matches, true) }
                }
            } catch {}
            return (matches, false)
        } onCancel: {
            running.stop()
        }
        if limited { running.stop() }
        var status: Int32 = -1
        for await code in exited.stream { status = code }
        // rg exits 0 with matches, 1 with none, 2 on an error (matches found
        // before an unreadable file still count).
        if !limited, !Task.isCancelled, status > 1, matches.isEmpty { return .failed(status: status) }
        return .matches(matches, limited: limited)
    }
}

/// `Process` is not Sendable; the cancellation handler only signals it.
private nonisolated final class RunningProcess: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}
