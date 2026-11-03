import CmuxNextCompat
package import Foundation

/// One ripgrep match: a line of a file under the searched directory.
package nonisolated struct RipgrepMatch: Equatable, Sendable {
    package let path: String
    package let relativePath: String
    /// 1-based.
    package let line: Int
    /// 1-based, in UTF-16 code units (the code editor's column).
    package let column: Int
    package let preview: String

    package init(path: String, relativePath: String, line: Int, column: Int, preview: String) {
        self.path = path
        self.relativePath = relativePath
        self.line = line
        self.column = column
        self.preview = preview
    }
}

/// Find in Directory's search: `rg` over a local directory, run the way the
/// old app's file explorer ran it (fixed strings, smart case, hidden files,
/// VCS and build folders skipped), stopped after `limit` matches.
package nonisolated struct RipgrepSearch {
    package nonisolated init() {}
    package nonisolated enum Outcome: Equatable, Sendable {
        case matches([RipgrepMatch], limited: Bool)
        /// rg failed before finding anything (exit status 2: a bad path or
        /// an unreadable directory).
        case failed(status: Int32)
    }

    /// The old app's cap.
    package static let limit = 500

    package static let excludedGlobs = [
        "!.git/**", "!**/.git/**",
        "!node_modules/**", "!**/node_modules/**",
        "!dist/**", "!**/dist/**",
        "!build/**", "!**/build/**",
        "!DerivedData/**", "!**/DerivedData/**",
    ]

    /// `rg`: the usual install locations first (a Finder-launched app gets
    /// launchd's short PATH), then PATH.
    package static func executable(
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

    package static func arguments(query: String, root: String) -> [String] {
        ["--json", "--line-number", "--column", "--smart-case", "--fixed-strings",
         "--max-columns", "300", "--max-columns-preview", "--color", "never", "--hidden"]
            + excludedGlobs.flatMap { ["--glob", $0] }
            + ["--", query, root]
    }

    /// A `--json` output line, if it is a match.
    package static func parse(_ line: String, root: String) -> RipgrepMatch? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "match",
              let payload = object["data"] as? [String: Any],
              let path = (payload["path"] as? [String: Any]).flatMap(text),
              let lines = (payload["lines"] as? [String: Any]).flatMap(text),
              let lineNumber = payload["line_number"] as? Int else { return nil }
        let start = (payload["submatches"] as? [[String: Any]])?.first?["start"] as? Int
        return RipgrepMatch(path: path, relativePath: relativePath(path, root: root), line: lineNumber,
                            column: utf16Column(lines, byteOffset: start ?? 0), preview: lines.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The 1-based UTF-16 column (the code editor's) of the match rg reports `byteOffset` UTF-8
    /// bytes into `line`.
    package static func utf16Column(_ line: String, byteOffset: Int) -> Int {
        let bytes = line.utf8.prefix(max(0, byteOffset))
        return String(decoding: bytes, as: UTF8.self).utf16.count + 1
    }

    /// rg writes non-UTF-8 text as base64 `bytes`.
    private static func text(_ object: [String: Any]) -> String? {
        if let text = object["text"] as? String { return text }
        guard let bytes = (object["bytes"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    package static func relativePath(_ path: String, root: String) -> String {
        let root = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    /// Runs `rg`, off the main actor. Stops it at `limit` matches or when
    /// the caller is cancelled.
    @concurrent package static func run(_ executable: URL, query: String, root: String, limit: Int = limit) async -> Outcome {
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
        // The reading task and its cancellation handler both stop rg. The Process (not Sendable on
        // the Xcode 26 SDK) moves into the lock, so each side reaches it only under the lock: a
        // short synchronous critical section called from the synchronous cancellation handler
        // (CLAUDE.md lock carve-out).
        let running = Mutex(process)
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
            stop(running)
        }
        if limited { stop(running) }
        var status: Int32 = -1
        for await code in exited.stream { status = code }
        // rg exits 0 with matches, 1 with none, 2 on an error (matches found
        // before an unreadable file still count).
        if !limited, !Task.isCancelled, status > 1, matches.isEmpty { return .failed(status: status) }
        return .matches(matches, limited: limited)
    }
}

/// Stops `rg` if it still runs (a search past its limit, or cancelled).
private nonisolated func stop(_ running: borrowing Mutex<Process>) {
    running.withLock { process in
        if process.isRunning { process.terminate() }
    }
}
