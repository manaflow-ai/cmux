import CMUXAgentLaunch
import Foundation

enum AgentHibernationTranscriptGuard {
    static let restoreCheckDelaysSeconds: [UInt64] = [20, 60, 180, 600]
    private static let maxScannedLineBytes = 16 * 1024 * 1024

    static func resolveTranscriptPath(
        agent: SessionRestorableAgentSnapshot,
        panelKey: AgentHibernationPanelKey? = nil,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> String? {
        guard agent.kind == .claude,
              isSafeSessionIdPathComponent(agent.sessionId) else {
            return nil
        }
        return resolveClaudeTranscriptPath(
            agent: agent,
            panelKey: panelKey,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }

    static func transcriptHasConversationTurns(
        atPath path: String,
        fileManager: FileManager = .default,
        maxScannedLineBytes: Int = Self.maxScannedLineBytes
    ) -> Bool {
        guard fileManager.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else {
            return false
        }
        defer { try? handle.close() }

        var buffered = Data()
        var discardingOversizedLine = false
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024),
                  !chunk.isEmpty else {
                guard !discardingOversizedLine,
                      buffered.count <= maxScannedLineBytes else {
                    return false
                }
                return lineDataHasConversationTurn(buffered)
            }

            var chunkRemainder = chunk[chunk.startIndex..<chunk.endIndex]
            if discardingOversizedLine {
                guard let newlineIndex = chunkRemainder.firstIndex(of: 10) else { continue }
                chunkRemainder = chunk[chunk.index(after: newlineIndex)..<chunk.endIndex]
                discardingOversizedLine = false
            }

            buffered.append(contentsOf: chunkRemainder)
            while let newlineIndex = buffered.firstIndex(of: 10) {
                let lineData = Data(buffered[..<newlineIndex])
                buffered.removeSubrange(buffered.startIndex...newlineIndex)
                if lineData.count <= maxScannedLineBytes,
                   lineDataHasConversationTurn(lineData) {
                    return true
                }
            }
            if buffered.count > maxScannedLineBytes {
                // Oversized malformed lines are skipped, not fatal; later normal
                // turns must remain visible to avoid false-negative live scans.
                buffered.removeAll(keepingCapacity: true)
                discardingOversizedLine = true
            }
        }
    }

    static func snapshotBeforeTeardown(
        agent: SessionRestorableAgentSnapshot,
        panelKey: AgentHibernationPanelKey? = nil,
        homeDirectory: String = NSHomeDirectory(),
        snapshotDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> TeardownSnapshotOutcome {
        guard agent.kind == .claude else { return .nothingToProtect }
        guard isSafeSessionIdPathComponent(agent.sessionId) else { return .unableToProtect }

        guard let transcriptPath = resolveTranscriptPath(
            agent: agent,
            panelKey: panelKey,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) else {
            return .unableToProtect
        }

        if !transcriptHasConversationTurns(atPath: transcriptPath, fileManager: fileManager) {
            return transcriptContainsOnlyNonProtectiveMetadata(atPath: transcriptPath, fileManager: fileManager)
                ? .nothingToProtect
                : .unableToProtect
        }

        guard let directory = snapshotDirectory ?? defaultSnapshotDirectoryURL() else {
            return .unableToProtect
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            pruneOldSnapshots(in: directory, fileManager: fileManager)
            let snapshotURL = directory.appendingPathComponent("\(agent.sessionId)-\(UUID().uuidString).jsonl", isDirectory: false)
            try fileManager.copyItem(atPath: transcriptPath, toPath: snapshotURL.path)
            let copiedSnapshotHasConversation = transcriptHasConversationTurns(
                atPath: snapshotURL.path,
                fileManager: fileManager
            )
            guard copiedSnapshotHasConversation else {
                try? fileManager.removeItem(at: snapshotURL)
                return .unableToProtect
            }
            guard let liveFileVersion = matchingLiveFileVersion(
                transcriptPath,
                snapshotURL.path,
                fileManager: fileManager
            ) else {
                // The live path may have advanced, or an older restore monitor may
                // have won a replace race. Keep the populated copy for recovery in
                // the session's single retained slot so repeated failed attempts
                // replace it instead of accumulating full-transcript copies.
                retainSnapshotForRecovery(
                    TeardownTranscriptSnapshot(transcriptPath: transcriptPath, snapshotPath: snapshotURL.path),
                    sessionId: agent.sessionId,
                    fileManager: fileManager
                )
                return .unableToProtect
            }
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
            return .snapshot(TeardownTranscriptSnapshot(
                transcriptPath: transcriptPath,
                snapshotPath: snapshotURL.path,
                liveFileVersion: liveFileVersion
            ))
        } catch {
            return .unableToProtect
        }
    }

    @discardableResult
    static func restoreIfClobbered(
        _ snapshot: TeardownTranscriptSnapshot,
        fileManager: FileManager = .default
    ) -> Bool {
        let transcriptURL = URL(fileURLWithPath: snapshot.transcriptPath)
        let protectedExists = fileManager.fileExists(atPath: transcriptURL.path)
        let protectedAttributes = try? fileManager.attributesOfItem(atPath: transcriptURL.path)
        let protectedFile = (protectedAttributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        let protectedSize = (protectedAttributes?[.size] as? NSNumber)?.uint64Value
        let protectedModificationDate = protectedAttributes?[.modificationDate] as? Date
        guard transcriptHasConversationTurns(atPath: snapshot.snapshotPath, fileManager: fileManager),
              !transcriptHasConversationTurns(atPath: snapshot.transcriptPath, fileManager: fileManager) else {
            return false
        }
        guard !protectedExists || transcriptContainsOnlyNonProtectiveMetadata(atPath: snapshot.transcriptPath, fileManager: fileManager) else { return false }
        let classifiedAttributes = try? fileManager.attributesOfItem(atPath: transcriptURL.path)
        guard fileManager.fileExists(atPath: transcriptURL.path) == protectedExists,
              (classifiedAttributes?[.systemFileNumber] as? NSNumber)?.uint64Value == protectedFile,
              (classifiedAttributes?[.size] as? NSNumber)?.uint64Value == protectedSize,
              (classifiedAttributes?[.modificationDate] as? Date) == protectedModificationDate else { return false }

        let directoryURL = transcriptURL.deletingLastPathComponent()
        let tempURL = directoryURL.appendingPathComponent(".\(transcriptURL.lastPathComponent).restore-\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: tempURL)
            try fileManager.copyItem(atPath: snapshot.snapshotPath, toPath: tempURL.path)
            try appendLiveStubIfPresent(from: transcriptURL, toRestoreFile: tempURL, fileManager: fileManager)
            let currentAttributes = try? fileManager.attributesOfItem(atPath: transcriptURL.path)
            guard fileManager.fileExists(atPath: transcriptURL.path) == protectedExists,
                  (currentAttributes?[.systemFileNumber] as? NSNumber)?.uint64Value == protectedFile,
                  (currentAttributes?[.size] as? NSNumber)?.uint64Value == protectedSize,
                  (currentAttributes?[.modificationDate] as? Date) == protectedModificationDate,
                  !protectedExists || transcriptContainsOnlyNonProtectiveMetadata(atPath: transcriptURL.path, fileManager: fileManager) else {
                try? fileManager.removeItem(at: tempURL)
                return false
            }
            if protectedExists {
                _ = try fileManager.replaceItemAt(transcriptURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: transcriptURL)
            }
            return true
        } catch {
            try? fileManager.removeItem(at: tempURL)
            return false
        }
    }

    /// Moves a populated snapshot whose live path drifted into the session's
    /// single retained recovery slot. Repeated failed protection attempts
    /// replace the slot instead of accumulating full-transcript copies; the
    /// slot ages out through the regular snapshot pruning. Never touches the
    /// UUID-suffixed snapshots that active restore monitors own.
    static func retainSnapshotForRecovery(
        _ snapshot: TeardownTranscriptSnapshot,
        sessionId: String?,
        fileManager: FileManager = .default
    ) {
        let snapshotURL = URL(fileURLWithPath: snapshot.snapshotPath)
        guard let sessionId, isSafeSessionIdPathComponent(sessionId) else {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
            return
        }
        let retainedURL = snapshotURL.deletingLastPathComponent()
            .appendingPathComponent("\(sessionId)-retained.jsonl", isDirectory: false)
        guard retainedURL.path != snapshotURL.path else {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: retainedURL.path)
            return
        }
        do {
            try? fileManager.removeItem(at: retainedURL)
            try fileManager.moveItem(at: snapshotURL, to: retainedURL)
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: retainedURL.path)
        } catch {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
        }
    }

    static func transcriptCandidates(projectRoot: String, sessionId: String) -> [String] {
        let directPath = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        let nestedPath = (((projectRoot as NSString).appendingPathComponent(sessionId) as NSString).appendingPathComponent("messages") as NSString).appendingPathComponent("\(sessionId).jsonl")
        return [directPath, nestedPath]
    }

    private static func isSafeSessionIdPathComponent(_ sessionId: String) -> Bool {
        !sessionId.isEmpty && sessionId != "." && sessionId != ".." && !sessionId.contains("/")
    }

    // Mirrors regularNonEmptyFileExists in RestorableAgentSession.swift: an empty
    // recorded/derived file must not shadow a populated transcript elsewhere.
    static func isRegularFile(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular else {
            return false
        }
        return ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0
    }

    private static func directoryExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func recordedTranscriptPath(
        agent: SessionRestorableAgentSnapshot,
        panelKey: AgentHibernationPanelKey?,
        homeDirectory: String,
        fileManager: FileManager
    ) -> (path: String?, isAmbiguous: Bool) {
        let storeURL = RestorableAgentKind.claude.hookStoreFileURL(homeDirectory: homeDirectory)
        guard let data = fileManager.contents(atPath: storeURL.path),
              let store = try? JSONDecoder().decode(AgentHibernationTranscriptHookStoreFileMirror.self, from: data),
              let sessions = store.sessions else {
            return (nil, false)
        }

        var paths: [String] = []
        var seenPaths: Set<String> = []
        for record in sessions.values {
            guard normalized(record.sessionId) == agent.sessionId,
                  panelKey.map({ record.matches(panelKey: $0) }) ?? true,
                  let transcriptPath = normalized(record.transcriptPath) else {
                continue
            }
            let expandedPath = expandTilde(in: transcriptPath, homeDirectory: homeDirectory)
            let standardizedPath = (expandedPath as NSString).standardizingPath
            if seenPaths.insert(standardizedPath).inserted,
               isRegularFile(atPath: expandedPath, fileManager: fileManager) {
                paths.append(expandedPath)
            }
        }
        guard let path = paths.first else { return (nil, false) }
        return paths.count == 1 ? (path, false) : (nil, true)
    }

    static func claudeConfigRoots(
        for agent: SessionRestorableAgentSnapshot,
        homeDirectory: String,
        fileManager: FileManager
    ) -> [String] {
        if let override = normalized(agent.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]) {
            let expanded = expandTilde(in: override, homeDirectory: homeDirectory)
            return [ClaudeConfigDirectoryPath.preferredPath(expanded, fileManager: fileManager, homeDirectory: homeDirectory)]
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
        appendRoot(ClaudeConfigDirectoryPath.preferredPath(
            (homeDirectory as NSString).appendingPathComponent(".subrouter/codex/claude"),
            fileManager: fileManager,
            homeDirectory: homeDirectory)
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

    static func transcriptContainsOnlyNonProtectiveMetadata(
        atPath path: String,
        fileManager: FileManager,
        maxScannedLineBytes: Int = Self.maxScannedLineBytes
    ) -> Bool {
        guard fileManager.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else {
            return false
        }
        defer { try? handle.close() }

        var sawMetadata = false
        var buffered = Data()
        while true {
            let chunk: Data
            do { chunk = try handle.read(upToCount: 64 * 1024) ?? Data() } catch { return false }
            guard !chunk.isEmpty else {
                guard buffered.count <= maxScannedLineBytes,
                      lineDataIsNonProtectiveMetadata(buffered, sawMetadata: &sawMetadata) else {
                    return false
                }
                return true
            }

            buffered.append(chunk)
            while let newlineIndex = buffered.firstIndex(of: 10) {
                let lineData = Data(buffered[..<newlineIndex])
                buffered.removeSubrange(buffered.startIndex...newlineIndex)
                guard lineData.count <= maxScannedLineBytes,
                      lineDataIsNonProtectiveMetadata(lineData, sawMetadata: &sawMetadata) else {
                    return false
                }
            }
            if buffered.count > maxScannedLineBytes {
                return false
            }
        }
    }

    private static func lineDataIsNonProtectiveMetadata(_ data: Data, sawMetadata: inout Bool) -> Bool {
        guard let line = String(data: data, encoding: .utf8) else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
              let type = object["type"] as? String else {
            return false
        }
        guard type == "last-prompt" || type == "ai-title" || type == "mode" else { return false }
        sawMetadata = true
        return true
    }

    private static func appendLiveStubIfPresent(
        from stubURL: URL,
        toRestoreFile restoreURL: URL,
        fileManager: FileManager
    ) throws {
        guard isRegularFile(atPath: stubURL.path, fileManager: fileManager) else { return }

        let output = try FileHandle(forUpdating: restoreURL)
        defer { try? output.close() }
        let endOffset = try output.seekToEnd()
        let trimmedOffset = try offsetByTrimmingTrailingNewlines(handle: output, endOffset: endOffset)
        try output.truncate(atOffset: trimmedOffset)
        try output.seekToEnd()
        try output.write(contentsOf: Data([10]))

        let input = try FileHandle(forReadingFrom: stubURL)
        defer { try? input.close() }
        var skippingLeadingNewlines = true
        while let chunk = try input.read(upToCount: 64 * 1024),
              !chunk.isEmpty {
            var bytes = chunk[chunk.startIndex..<chunk.endIndex]
            if skippingLeadingNewlines {
                guard let firstContentIndex = bytes.firstIndex(where: { $0 != 10 && $0 != 13 }) else {
                    continue
                }
                bytes = chunk[firstContentIndex..<chunk.endIndex]
                skippingLeadingNewlines = false
            }
            try output.write(contentsOf: bytes)
        }
    }

    private static func offsetByTrimmingTrailingNewlines(handle: FileHandle, endOffset: UInt64) throws -> UInt64 {
        var remainingEnd = endOffset
        while remainingEnd > 0 {
            let readSize = min(UInt64(64 * 1024), remainingEnd)
            let startOffset = remainingEnd - readSize
            try handle.seek(toOffset: startOffset)
            guard let data = try handle.read(upToCount: Int(readSize)),
                  !data.isEmpty else {
                return remainingEnd
            }
            var index = data.endIndex
            while index > data.startIndex {
                let previous = data.index(before: index)
                let byte = data[previous]
                if byte != 10 && byte != 13 {
                    return startOffset + UInt64(data.distance(from: data.startIndex, to: index))
                }
                index = previous
            }
            remainingEnd = startOffset
        }
        return 0
    }

    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func expandTilde(in path: String, homeDirectory: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = (homeDirectory as NSString).expandingTildeInPath
        guard path != "~" else { return home }
        return (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
    }
}
