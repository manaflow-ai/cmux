import CmuxAgentChat
import Foundation

/// Builds and caches the transcript-derived artifact scope for chat sessions.
actor AgentChatArtifactIndex {
    static let shared = AgentChatArtifactIndex()

    struct Snapshot: Sendable {
        let referencedPaths: Set<String>
        let artifacts: [ChatArtifactIndexedReference]
        let generation: String
    }

    enum Operation: Sendable {
        case file
        case list
    }

    enum CanonicalPathResult: Sendable {
        case success(String)
        case canonicalizationFailed
        case notInSet
    }

    struct SupplementalAttachment: Sendable, Equatable {
        let path: String
        let sourceSeq: Int
    }

    private struct CacheKey: Sendable, Equatable {
        let transcriptPath: String
        let workingDirectory: String?
        let fileSize: UInt64
        let modifiedAt: Date

        var generation: String {
            "\(fileSize)-\(Int64(modifiedAt.timeIntervalSince1970 * 1_000_000))"
        }
    }

    private struct CacheEntry: Sendable {
        let key: CacheKey
        let snapshot: Snapshot
    }

    private struct SupplementalRegistration: Sendable {
        let transcriptPath: String
        var attachmentsByPath: [String: RegisteredSupplementalAttachment]
        var revision: UInt64
    }

    private struct RegisteredSupplementalAttachment: Sendable {
        let attachment: SupplementalAttachment
        let accessOrdinal: UInt64
    }

    private var cacheBySessionID = ChatArtifactLRUCache<String, CacheEntry>(capacity: 8)
    private var supplementalBySessionID: [String: SupplementalRegistration] = [:]
    private var supplementalSessionOrder: [String] = []
    private var nextSupplementalAccessOrdinal: UInt64 = 0
    private static let supplementalSessionCapacity = 64
    private static let supplementalPathCapacity = 2_048

    func registerAttachments(
        sessionID: String,
        transcriptPath: String,
        attachments: [SupplementalAttachment]
    ) {
        guard !sessionID.isEmpty,
              !transcriptPath.isEmpty,
              !attachments.isEmpty else { return }
        let normalizedTranscriptPath = URL(fileURLWithPath: transcriptPath)
            .standardizedFileURL.path
        var next = supplementalBySessionID[sessionID]
        if next?.transcriptPath != normalizedTranscriptPath {
            next = SupplementalRegistration(
                transcriptPath: normalizedTranscriptPath,
                attachmentsByPath: [:],
                revision: 0
            )
        }
        guard var registration = next else { return }
        let resolver = ChatArtifactScope.FoundationResolver()
        var changed = false
        for attachment in attachments.sorted(by: { $0.sourceSeq > $1.sourceSeq }) {
            guard attachment.path.utf8.count <= 4_096,
                  attachment.path.hasPrefix("/"),
                  let canonicalPath = ChatArtifactScope.canonicalizedPath(
                    attachment.path,
                    resolver: resolver
                  ),
                  resolver.isDirectory(canonicalPath) == false else { continue }
            let candidate = SupplementalAttachment(
                path: canonicalPath,
                sourceSeq: max(
                    registration.attachmentsByPath[canonicalPath]?.attachment.sourceSeq ?? Int.min,
                    attachment.sourceSeq
                )
            )
            let previous = registration.attachmentsByPath[canonicalPath]
            nextSupplementalAccessOrdinal &+= 1
            registration.attachmentsByPath[canonicalPath] = RegisteredSupplementalAttachment(
                attachment: candidate,
                accessOrdinal: nextSupplementalAccessOrdinal
            )
            if previous?.attachment != candidate {
                changed = true
            }
        }
        if registration.attachmentsByPath.count > Self.supplementalPathCapacity {
            let overflow = registration.attachmentsByPath.count - Self.supplementalPathCapacity
            let evictedPaths = registration.attachmentsByPath.values
                .sorted { $0.accessOrdinal < $1.accessOrdinal }
                .prefix(overflow)
                .map(\.attachment.path)
            for path in evictedPaths {
                registration.attachmentsByPath[path] = nil
            }
            changed = true
        }
        guard !registration.attachmentsByPath.isEmpty else { return }
        guard changed else {
            supplementalBySessionID[sessionID] = registration
            touchSupplementalSession(sessionID)
            evictSupplementalSessionsIfNeeded()
            return
        }
        registration.revision &+= 1
        supplementalBySessionID[sessionID] = registration
        touchSupplementalSession(sessionID)
        evictSupplementalSessionsIfNeeded()
    }

    func removeSupplementalAttachments(sessionID: String) {
        supplementalBySessionID[sessionID] = nil
        supplementalSessionOrder.removeAll { $0 == sessionID }
    }

    func snapshot(
        sessionID: String,
        agentKind: ChatAgentKind,
        transcriptPath: String,
        workingDirectory: String?
    ) async throws -> Snapshot {
        let key = try Self.cacheKey(transcriptPath: transcriptPath, workingDirectory: workingDirectory)
        if let cached = cacheBySessionID.value(forKey: sessionID), cached.key == key {
            return snapshotByMergingSupplemental(
                cached.snapshot,
                sessionID: sessionID,
                transcriptPath: transcriptPath
            )
        }
        let snapshot = try Self.buildSnapshot(
            agentKind: agentKind,
            transcriptPath: transcriptPath,
            workingDirectory: workingDirectory,
            generation: key.generation
        )
        cacheBySessionID.insert(CacheEntry(key: key, snapshot: snapshot), forKey: sessionID)
        return snapshotByMergingSupplemental(
            snapshot,
            sessionID: sessionID,
            transcriptPath: transcriptPath
        )
    }

    func canonicalPath(
        sessionID: String,
        agentKind: ChatAgentKind,
        transcriptPath: String,
        workingDirectory: String?,
        requestedPath: String,
        operation: Operation,
        directoryAccessMode: ChatArtifactScope.DirectoryAccessMode
    ) async throws -> CanonicalPathResult {
        let resolver = ChatArtifactScope.FoundationResolver()
        guard let canonicalRequestedPath = ChatArtifactScope.canonicalizedPath(
            requestedPath,
            resolver: resolver
        ) else {
            return .canonicalizationFailed
        }
        if case .file = operation,
           var registration = supplementalBySessionID[sessionID],
           registration.transcriptPath
            == URL(fileURLWithPath: transcriptPath).standardizedFileURL.path,
           let registered = registration.attachmentsByPath[canonicalRequestedPath] {
            nextSupplementalAccessOrdinal &+= 1
            registration.attachmentsByPath[canonicalRequestedPath] = RegisteredSupplementalAttachment(
                attachment: registered.attachment,
                accessOrdinal: nextSupplementalAccessOrdinal
            )
            supplementalBySessionID[sessionID] = registration
            touchSupplementalSession(sessionID)
            return .success(canonicalRequestedPath)
        }
        let snapshot = try await snapshot(
            sessionID: sessionID,
            agentKind: agentKind,
            transcriptPath: transcriptPath,
            workingDirectory: workingDirectory
        )
        let canonicalPath: String?
        let scope = ChatArtifactScope(
            referencedPaths: snapshot.referencedPaths,
            directoryAccessMode: directoryAccessMode,
            resolver: resolver
        )
        switch operation {
        case .file:
            canonicalPath = scope.canonicalFilePath(for: requestedPath)
        case .list:
            canonicalPath = scope.canonicalDirectoryListPath(for: requestedPath)
        }
        return canonicalPath.map(CanonicalPathResult.success) ?? .notInSet
    }

    private static func cacheKey(transcriptPath: String, workingDirectory: String?) throws -> CacheKey {
        let attributes = try FileManager.default.attributesOfItem(atPath: transcriptPath)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        return CacheKey(
            transcriptPath: transcriptPath,
            workingDirectory: workingDirectory,
            fileSize: size,
            modifiedAt: modifiedAt
        )
    }

    private func snapshotByMergingSupplemental(
        _ snapshot: Snapshot,
        sessionID: String,
        transcriptPath: String
    ) -> Snapshot {
        guard let registration = supplementalBySessionID[sessionID],
              registration.transcriptPath == URL(fileURLWithPath: transcriptPath).standardizedFileURL.path,
              !registration.attachmentsByPath.isEmpty else { return snapshot }
        touchSupplementalSession(sessionID)
        var artifactsByPath = Dictionary(uniqueKeysWithValues: snapshot.artifacts.map { ($0.path, $0) })
        for registered in registration.attachmentsByPath.values {
            let attachment = registered.attachment
            let previous = artifactsByPath[attachment.path]
            let provenance: ChatArtifactProvenance = previous?.provenance == .created
                ? .created
                : .attached
            artifactsByPath[attachment.path] = ChatArtifactIndexedReference(
                path: attachment.path,
                provenance: provenance,
                lastReferencedSeq: max(previous?.lastReferencedSeq ?? Int.min, attachment.sourceSeq)
            )
        }
        return Snapshot(
            referencedPaths: snapshot.referencedPaths.union(registration.attachmentsByPath.keys),
            artifacts: Array(artifactsByPath.values),
            generation: "\(snapshot.generation)-supplemental-\(registration.revision)"
        )
    }

    private func touchSupplementalSession(_ sessionID: String) {
        supplementalSessionOrder.removeAll { $0 == sessionID }
        supplementalSessionOrder.append(sessionID)
    }

    private func evictSupplementalSessionsIfNeeded() {
        while supplementalSessionOrder.count > Self.supplementalSessionCapacity {
            let evicted = supplementalSessionOrder.removeFirst()
            supplementalBySessionID[evicted] = nil
        }
    }

    private static func buildSnapshot(
        agentKind: ChatAgentKind,
        transcriptPath: String,
        workingDirectory: String?,
        generation: String
    ) throws -> Snapshot {
        let data = try Data(contentsOf: URL(fileURLWithPath: transcriptPath), options: .mappedIfSafe)
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parseResult: ChatTranscriptParseResult
        switch agentKind {
        case .codex:
            parseResult = CodexTranscriptParser().parse(lines: lines, startingSeq: 0)
        case .claude, .other:
            parseResult = ClaudeTranscriptParser().parse(lines: lines, startingSeq: 0)
        }
        let artifacts = ChatArtifactIndexedReference.derive(
            from: parseResult.messages,
            supplementalReferences: parseResult.artifactReferences,
            workingDirectory: workingDirectory
        )
        let referencedPaths = Set(artifacts.map(\.path))
        return Snapshot(
            referencedPaths: referencedPaths,
            artifacts: artifacts,
            generation: generation
        )
    }
}
