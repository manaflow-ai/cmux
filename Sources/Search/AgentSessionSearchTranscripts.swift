import CmuxAgentChat
import Dispatch
import Foundation

/// A live agent session as Global Search indexes it.
struct AgentSessionSearchSource: Sendable, Equatable {
    /// Where the session's transcript is.
    enum Transcript: Sendable, Equatable {
        /// A path the resolver vouched for (`boundedTranscriptPath`).
        case path(String)
        /// A Codex rollout still to be found, off the main actor.
        case codexRollout(CodexRolloutLookup)
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
/// and parsing run on a dedicated utility queue, never on the main actor or
/// a cooperative-pool thread (the same split `AgentUsageSampler` uses).
actor AgentSessionSearchTranscripts: AgentSessionTranscriptStore {
    private var readers: [String: AgentSessionSearchTranscript] = [:]
    private var revisions: [String: Int] = [:]
    private var readsInFlight: Set<String> = []
    private var nextRevision = 1
    private let readQueue = DispatchQueue(
        label: "com.cmux.global-search.agent-transcript-reads",
        qos: .utility
    )

    /// Finds the session's transcript and reads its new bytes, both on the
    /// read queue.
    ///
    /// A refresh that finds the same session already being read returns the
    /// revision of the text read so far instead of reading twice.
    ///
    /// - Returns: A revision that changes whenever the session's text changes
    ///   (unique across sessions), or nil while the transcript has no text or
    ///   can't be found.
    func refreshedRevision(for source: AgentSessionSearchSource) async -> Int? {
        let sessionID = source.sessionID
        guard !readsInFlight.contains(sessionID) else { return currentRevision(forSessionID: sessionID) }

        readsInFlight.insert(sessionID)
        defer { readsInFlight.remove(sessionID) }
        let existing = readers[sessionID]
        let readQueue = self.readQueue
        let read = await withCheckedContinuation { (continuation: CheckedContinuation<Read?, Never>) in
            readQueue.async {
                continuation.resume(returning: Self.readTranscript(source, existing: existing))
            }
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

    /// Resolves the transcript and reads what it gained. Blocking; runs on
    /// the read queue.
    private static func readTranscript(_ source: AgentSessionSearchSource, existing: AgentSessionSearchTranscript?) -> Read? {
        guard let path = transcriptPath(for: source, cachedPath: existing?.path) else { return nil }
        let reusable = existing.flatMap { $0.path == path && $0.agentKind == source.agentKind ? $0 : nil }
        var reader = reusable ?? AgentSessionSearchTranscript(path: path, agentKind: source.agentKind)
        let changed = reader.refresh()
        return Read(reader: reader, changed: changed || reusable == nil)
    }

    /// The path to read. A Codex rollout keeps the path last read while that
    /// file exists, so libproc and the directory listing run once per session
    /// rather than on every palette open.
    static func transcriptPath(for source: AgentSessionSearchSource, cachedPath: String?) -> String? {
        switch source.transcript {
        case .path(let path):
            return path
        case .codexRollout(let lookup):
            if let cachedPath, FileManager.default.fileExists(atPath: cachedPath) {
                return cachedPath
            }
            return lookup.livePath()
        }
    }

    /// The session's current document text, as of the last refresh.
    func text(forSessionID sessionID: String) -> String? {
        guard let text = readers[sessionID]?.text, !text.isEmpty else { return nil }
        return text.documentText
    }

    /// Drops readers for sessions no longer indexed.
    func retainOnly(sessionIDs: Set<String>) {
        readers = readers.filter { sessionIDs.contains($0.key) }
        revisions = revisions.filter { sessionIDs.contains($0.key) }
    }

    private func currentRevision(forSessionID sessionID: String) -> Int? {
        guard let reader = readers[sessionID], !reader.text.isEmpty else { return nil }
        return revisions[sessionID]
    }
}
