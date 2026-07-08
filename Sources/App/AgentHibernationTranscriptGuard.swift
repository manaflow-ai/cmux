import CMUXAgentLaunch
import Darwin
import Foundation

enum AgentHibernationTranscriptGuard {
    struct TeardownTranscriptSnapshot: Sendable {
        let transcriptPath: String
        let snapshotPath: String
    }

    static let restoreCheckDelaysSeconds: [UInt64] = [20, 60, 180, 600]

    static func runPostTeardownRestoreChecks(
        snapshot: TeardownTranscriptSnapshot,
        processIDs: Set<Int>,
        fileManager: FileManager = .default
    ) async {
        if !processIDs.isEmpty {
            // Bound the wait for signaled processes to disappear before checking.
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ContinuousClock.now < deadline {
                let anyAlive = processIDs.contains { pid in
                    pid > 0 && pid <= Int(Int32.max) && kill(pid_t(pid), 0) == 0
                }
                if !anyAlive { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        // The exit-path rewrite lands within seconds of SIGTERM/pty-close; check
        // immediately after a short settle so a quick user resume cannot beat the
        // restore, then fall through to the escalating backstop.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if restoreIfClobbered(snapshot, fileManager: fileManager) { return }

        // Backstop for SIGHUP-only teardowns with no tracked pid, and for
        // stragglers past the bounded process-exit window.
        for delaySeconds in restoreCheckDelaysSeconds {
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            if restoreIfClobbered(snapshot, fileManager: fileManager) {
                return
            }
        }
    }

    static func resolveTranscriptPath(
        agent: SessionRestorableAgentSnapshot,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> String? {
        guard agent.kind == .claude,
              let workingDirectory = normalized(agent.workingDirectory) else {
            return nil
        }

        for configRoot in claudeConfigRoots(for: agent, homeDirectory: homeDirectory, fileManager: fileManager) {
            let projectRoot = ((configRoot as NSString).appendingPathComponent("projects") as NSString)
                .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(workingDirectory))
            for candidate in transcriptCandidates(projectRoot: projectRoot, sessionId: agent.sessionId) {
                if isRegularFile(atPath: candidate, fileManager: fileManager) {
                    return candidate
                }
            }
        }
        return nil
    }

    static func transcriptHasConversationTurns(
        atPath path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else {
            return false
        }
        defer { try? handle.close() }

        var buffered = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024),
                  !chunk.isEmpty else {
                return lineDataHasConversationTurn(buffered)
            }
            buffered.append(chunk)
            while let newlineIndex = buffered.firstIndex(of: 10) {
                let lineData = Data(buffered[..<newlineIndex])
                buffered.removeSubrange(buffered.startIndex...newlineIndex)
                if lineDataHasConversationTurn(lineData) {
                    return true
                }
            }
        }
    }

    static func snapshotBeforeTeardown(
        agent: SessionRestorableAgentSnapshot,
        homeDirectory: String = NSHomeDirectory(),
        snapshotDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> TeardownTranscriptSnapshot? {
        guard let transcriptPath = resolveTranscriptPath(
            agent: agent,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ),
            transcriptHasConversationTurns(atPath: transcriptPath, fileManager: fileManager),
            let directory = snapshotDirectory ?? defaultSnapshotDirectoryURL() else {
            return nil
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            pruneOldSnapshots(in: directory, fileManager: fileManager)
            let snapshotURL = directory.appendingPathComponent("\(agent.sessionId).jsonl", isDirectory: false)
            if fileManager.fileExists(atPath: snapshotURL.path) {
                try fileManager.removeItem(at: snapshotURL)
            }
            try fileManager.copyItem(atPath: transcriptPath, toPath: snapshotURL.path)
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
            return TeardownTranscriptSnapshot(
                transcriptPath: transcriptPath,
                snapshotPath: snapshotURL.path
            )
        } catch {
            return nil
        }
    }

    @discardableResult
    static func restoreIfClobbered(
        _ snapshot: TeardownTranscriptSnapshot,
        fileManager: FileManager = .default
    ) -> Bool {
        guard transcriptHasConversationTurns(atPath: snapshot.snapshotPath, fileManager: fileManager),
              !transcriptHasConversationTurns(atPath: snapshot.transcriptPath, fileManager: fileManager),
              let snapshotData = fileManager.contents(atPath: snapshot.snapshotPath) else {
            return false
        }

        var restoreData = snapshotData
        if let stubData = fileManager.contents(atPath: snapshot.transcriptPath),
           !stubData.isEmpty {
            appendSingleNewlineIfNeeded(to: &restoreData)
            var trailing = stubData
            removeLeadingNewlines(from: &trailing)
            restoreData.append(trailing)
        }

        do {
            let transcriptURL = URL(fileURLWithPath: snapshot.transcriptPath)
            try fileManager.createDirectory(
                at: transcriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try restoreData.write(to: transcriptURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func transcriptCandidates(projectRoot: String, sessionId: String) -> [String] {
        let directPath = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        let nestedPath = (((projectRoot as NSString).appendingPathComponent(sessionId) as NSString)
            .appendingPathComponent("messages") as NSString)
            .appendingPathComponent("\(sessionId).jsonl")
        return [directPath, nestedPath]
    }

    private static func isRegularFile(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              let fileType = attributes[.type] as? FileAttributeType else {
            return false
        }
        return fileType == .typeRegular
    }

    private static func directoryExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func claudeConfigRoots(
        for agent: SessionRestorableAgentSnapshot,
        homeDirectory: String,
        fileManager: FileManager
    ) -> [String] {
        if let override = normalized(agent.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]) {
            let expanded = expandTilde(in: override, homeDirectory: homeDirectory)
            return [
                ClaudeConfigDirectoryPath.preferredPath(
                    expanded,
                    fileManager: fileManager,
                    homeDirectory: homeDirectory
                ),
            ]
        }

        var roots: [String] = []
        var seen: Set<String> = []
        func appendRoot(_ path: String) {
            let standardized = (path as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }
            roots.append(standardized)
        }

        let accountRoot = (homeDirectory as NSString).appendingPathComponent(".codex-accounts/claude")
        if directoryExists(atPath: accountRoot, fileManager: fileManager),
           let accountDirs = try? fileManager.contentsOfDirectory(atPath: accountRoot) {
            for accountDir in accountDirs.sorted() {
                let accountPath = (accountRoot as NSString).appendingPathComponent(accountDir)
                guard directoryExists(atPath: accountPath, fileManager: fileManager) else { continue }
                appendRoot(accountPath)
            }
        }
        appendRoot((homeDirectory as NSString).appendingPathComponent(".claude"))
        appendRoot(
            ClaudeConfigDirectoryPath.preferredPath(
                (homeDirectory as NSString).appendingPathComponent(".subrouter/codex/claude"),
                fileManager: fileManager,
                homeDirectory: homeDirectory
            )
        )
        return roots
    }

    private static func defaultSnapshotDirectoryURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-transcript-teardown-snapshots", isDirectory: true)
    }

    private static func pruneOldSnapshots(in directory: URL, fileManager: FileManager) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        for url in urls {
            guard (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map({ $0 < cutoff }) == true else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func lineDataHasConversationTurn(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.range(of: Data(#""type""#.utf8)) != nil,
              (data.range(of: Data(#""user""#.utf8)) != nil ||
                  data.range(of: Data(#""assistant""#.utf8)) != nil),
              String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return false
        }
        return type == "user" || type == "assistant"
    }

    private static func appendSingleNewlineIfNeeded(to data: inout Data) {
        while data.last == 10 || data.last == 13 {
            data.removeLast()
        }
        data.append(10)
    }

    private static func removeLeadingNewlines(from data: inout Data) {
        while data.first == 10 || data.first == 13 {
            data.removeFirst()
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func expandTilde(in path: String, homeDirectory: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = (homeDirectory as NSString).expandingTildeInPath
        guard path != "~" else { return home }
        return (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
    }
}
