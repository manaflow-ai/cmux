import CMUXAgentLaunch
import Foundation

enum AgentHibernationTranscriptGuard {
    struct TeardownTranscriptSnapshot: Sendable {
        let transcriptPath: String
        let snapshotPath: String
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

        let configRoot: String
        if let override = normalized(agent.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]) {
            let expanded = expandTilde(in: override, homeDirectory: homeDirectory)
            configRoot = ClaudeConfigDirectoryPath.preferredPath(
                expanded,
                fileManager: fileManager,
                homeDirectory: homeDirectory
            )
        } else {
            configRoot = (homeDirectory as NSString).appendingPathComponent(".claude")
        }

        let projectRoot = ((configRoot as NSString).appendingPathComponent("projects") as NSString)
            .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(workingDirectory))
        for candidate in transcriptCandidates(projectRoot: projectRoot, sessionId: agent.sessionId) {
            if isRegularFile(atPath: candidate, fileManager: fileManager) {
                return candidate
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
