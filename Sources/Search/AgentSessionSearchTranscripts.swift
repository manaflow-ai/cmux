import CmuxAgentChat
import Dispatch
import Foundation

/// A live agent session as Global Search indexes it.
struct AgentSessionSearchSource: Sendable {
    /// Where the session's transcript is.
    enum Transcript: Sendable {
        /// A path the resolver vouched for (`boundedTranscriptPath`).
        case path(String)
        /// A Codex rollout still to be found, off the main actor.
        case codexRollout(CodexRolloutLookup)
        /// A live record whose transcript path is resolved off the main actor.
        case lookup(AgentSessionTranscriptLookup)
    }

    let sessionID: String
    let agentKind: ChatAgentKind
    let transcript: Transcript

    init(sessionID: String, agentKind: ChatAgentKind, transcript: Transcript) {
        self.sessionID = sessionID
        self.agentKind = agentKind
        self.transcript = transcript
    }

    init(sessionID: String, agentKind: ChatAgentKind, transcriptPath: String) {
        self.init(sessionID: sessionID, agentKind: agentKind, transcript: .path(transcriptPath))
    }
}

/// What the capture manager reads agent sessions through; tests stand in
/// for the transcript files.
protocol AgentSessionTranscriptStore: Sendable {
    func refreshedRevision(for source: AgentSessionSearchSource) async -> Int?
    func text(forSessionID sessionID: String) async -> String?
    func retainOnly(sessionIDs: Set<String>) async
}

/// Owns one incremental transcript reader per indexed agent session.
///
/// The actor only bookkeeps readers and revisions. The blocking file reads
/// and parsing run on a dedicated utility queue, never on the main actor.
actor AgentSessionSearchTranscripts: AgentSessionTranscriptStore {
    private var readers: [String: AgentSessionSearchTranscript] = [:]
    private var revisions: [String: Int] = [:]
    /// Shared read tasks keep overlapping palette refreshes from falling back
    /// to scrollback while the first transcript read is still in progress.
    private var readsInFlight: [String: Task<Int?, Never>] = [:]
    /// A prune increments the generation so an in-flight read cannot restore
    /// a reader that is no longer represented by an indexed panel.
    private var readerGenerations: [String: UInt64] = [:]
    private var nextRevision = 1
    private let codexRolloutPaths = CodexRolloutPathIndex()
    /// Blocking JSONL reads use a utility queue because detached tasks share
    /// Swift's cooperative pool with unrelated app work.
    private let readQueue = DispatchQueue(
        label: "com.cmux.global-search.agent-transcript-reads",
        qos: .utility
    )

    /// Finds the session's transcript and reads its new bytes off-actor.
    ///
    /// A refresh that finds the same session already being read awaits that
    /// read instead of returning an empty result and indexing scrollback.
    ///
    /// - Returns: A revision that changes whenever the session's text changes
    ///   (unique across sessions), or nil while the transcript has no text or
    ///   can't be found.
    func refreshedRevision(for source: AgentSessionSearchSource) async -> Int? {
        let sessionID = source.sessionID
        if let task = readsInFlight[sessionID] {
            return await task.value
        }

        let existing = readers[sessionID]
        let generation = readerGenerations[sessionID, default: 0]
        let task = Task { [weak self] () -> Int? in
            guard let self else { return nil }
            let read = await self.readTranscript(source, existing: existing)
            return await self.finishRead(
                read,
                sessionID: sessionID,
                generation: generation
            )
        }
        readsInFlight[sessionID] = task
        return await task.value
    }

    private func finishRead(
        _ read: Read?,
        sessionID: String,
        generation: UInt64
    ) -> Int? {
        defer { readsInFlight[sessionID] = nil }
        guard readerGenerations[sessionID, default: 0] == generation else {
            return nil
        }
        guard let read else {
            readers[sessionID] = nil
            revisions[sessionID] = nil
            return nil
        }
        if read.changed || revisions[sessionID] == nil {
            revisions[sessionID] = nextRevision
            nextRevision += 1
        }
        readers[sessionID] = read.reader
        return currentRevision(forSessionID: sessionID)
    }

    private struct Read: Sendable {
        let reader: AgentSessionSearchTranscript
        /// Whether the text changed, including a reader that started over.
        let changed: Bool
    }

    /// Resolves the transcript on the actor, then performs blocking file I/O
    /// on the dedicated utility queue.
    private func readTranscript(
        _ source: AgentSessionSearchSource,
        existing: AgentSessionSearchTranscript?
    ) async -> Read? {
        guard let path = await Self.transcriptPath(
            for: source,
            cachedPath: existing?.path,
            codexRolloutPaths: codexRolloutPaths
        ) else { return nil }
        let readQueue = self.readQueue
        return await withCheckedContinuation { continuation in
            readQueue.async {
                continuation.resume(returning: Self.readTranscript(
                    path: path,
                    agentKind: source.agentKind,
                    existing: existing
                ))
            }
        }
    }

    private static func readTranscript(
        path: String,
        agentKind: ChatAgentKind,
        existing: AgentSessionSearchTranscript?
    ) -> Read? {
        var reusable = existing
        if reusable?.path != path || reusable?.agentKind != agentKind {
            reusable = nil
        }
        var reader = reusable ?? AgentSessionSearchTranscript(path: path, agentKind: agentKind)
        let changed = reader.refresh()
        return Read(reader: reader, changed: changed || reusable == nil)
    }

    private static func transcriptPath(
        for source: AgentSessionSearchSource,
        cachedPath: String?,
        codexRolloutPaths: CodexRolloutPathIndex
    ) async -> String? {
        switch source.transcript {
        case .path(let path):
            return path
        case .codexRollout(let lookup):
            if let cachedPath, FileManager.default.fileExists(atPath: cachedPath) {
                return cachedPath
            }
            return await codexRolloutPaths.path(for: lookup)
        case .lookup(let lookup):
            // Re-resolve the record first so a hook or resume that points at a
            // new transcript switches readers immediately. A cached path is
            // only the fallback for Codex's path-less rollout lookup.
            if let path = await codexRolloutPaths.path(for: lookup) {
                return path
            }
            if let cachedPath, FileManager.default.fileExists(atPath: cachedPath) {
                return cachedPath
            }
            return nil
        }
    }

    /// The session's current document text, as of the last refresh.
    func text(forSessionID sessionID: String) -> String? {
        guard let text = readers[sessionID]?.text, !text.isEmpty else { return nil }
        return text.documentText
    }

    /// Drops readers for sessions no longer indexed.
    func retainOnly(sessionIDs: Set<String>) {
        let knownSessionIDs = Set(readers.keys)
            .union(revisions.keys)
            .union(readsInFlight.keys)
        for sessionID in knownSessionIDs where !sessionIDs.contains(sessionID) {
            readerGenerations[sessionID, default: 0] &+= 1
        }
        readers = readers.filter { sessionIDs.contains($0.key) }
        revisions = revisions.filter { sessionIDs.contains($0.key) }
    }

    private func currentRevision(forSessionID sessionID: String) -> Int? {
        guard let reader = readers[sessionID], !reader.text.isEmpty else { return nil }
        return revisions[sessionID]
    }
}

/// Caches the bounded Codex rollout-directory scan for one search refresh
/// service. Directory contents are rebuilt when their modification date
/// changes, so a newly-created rollout remains discoverable without rescanning
/// the same directory once per pane.
actor CodexRolloutPathIndex {
    private struct DirectoryEntry {
        let modificationDate: Date
        let pathsBySessionSuffix: [String: String]
    }

    private var entries: [String: DirectoryEntry] = [:]

    /// Resolves a rollout path using the live process first, then the cached
    /// today/yesterday directory indexes.
    func path(for lookup: CodexRolloutLookup, now: Date = Date()) -> String? {
        if let open = lookup.openProcessPath() {
            return open
        }
        let sessionIDs = lookup.sessionIDs.map { $0.lowercased() }
        for directory in lookup.rolloutDirectories(now: now) {
            let index = directoryIndex(for: directory)
            for sessionID in sessionIDs {
                if let path = index.pathsBySessionSuffix[sessionID] {
                    return path
                }
            }
        }
        return nil
    }

    /// Resolves the conventional path for a live record, keeping the
    /// resolver's recorded/Claude checks on this off-main lookup path.
    func path(for lookup: AgentSessionTranscriptLookup, now: Date = Date()) -> String? {
        if let path = lookup.resolver.boundedTranscriptPath(for: lookup.record) {
            return path
        }
        guard lookup.record.agentKind == .codex else { return nil }
        return path(
            for: CodexRolloutLookup(record: lookup.record, codexHome: lookup.resolver.codexConfigRoot),
            now: now
        )
    }

    private func directoryIndex(for directory: URL) -> DirectoryEntry {
        let path = directory.path
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        if let modificationDate, let cached = entries[path], cached.modificationDate == modificationDate {
            return cached
        }

        var pathsBySessionSuffix: [String: String] = [:]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for name in names where name.lowercased().hasSuffix(".jsonl") {
                let stem = String(name.dropLast(6)).lowercased()
                var index = stem.startIndex
                while index < stem.endIndex {
                    if stem[index] == "-" {
                        let suffixStart = stem.index(after: index)
                        if suffixStart < stem.endIndex {
                            pathsBySessionSuffix[String(stem[suffixStart...])] = directory
                                .appendingPathComponent(name)
                                .path
                        }
                    }
                    index = stem.index(after: index)
                }
            }
        }

        let entry = DirectoryEntry(
            modificationDate: modificationDate ?? .distantPast,
            pathsBySessionSuffix: pathsBySessionSuffix
        )
        if modificationDate != nil {
            entries[path] = entry
        }
        return entry
    }
}
