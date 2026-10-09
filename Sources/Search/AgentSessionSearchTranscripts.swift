import CmuxAgentChat
import Dispatch
import Foundation

/// A live agent session as Global Search indexes it.
struct AgentSessionSearchSource: Sendable, Equatable {
    let sessionID: String
    let agentKind: ChatAgentKind
    /// A transcript path the resolver vouched for (`boundedTranscriptPath`).
    let transcriptPath: String
    /// The name the session goes by: its conversation title, else the pane's.
    let title: String
    let workingDirectory: String?
}

/// Owns one incremental transcript reader per indexed agent session.
///
/// The actor only bookkeeps readers and revisions. The blocking file reads
/// and parsing run on a dedicated utility queue, never on the main actor or
/// a cooperative-pool thread (the same split `AgentUsageSampler` uses).
actor AgentSessionSearchTranscripts {
    private var readers: [String: AgentSessionSearchTranscript] = [:]
    private var revisions: [String: Int] = [:]
    private var readsInFlight: Set<String> = []
    private var nextRevision = 1
    private let readQueue = DispatchQueue(
        label: "com.cmux.global-search.agent-transcript-reads",
        qos: .utility
    )

    /// Reads the session's new transcript bytes.
    ///
    /// A refresh that finds the same session already being read returns the
    /// revision of the text read so far instead of reading twice.
    ///
    /// - Returns: A revision that changes whenever the session's text changes
    ///   (unique across sessions), or nil while the transcript has no text.
    func refreshedRevision(for source: AgentSessionSearchSource) async -> Int? {
        let sessionID = source.sessionID
        guard !readsInFlight.contains(sessionID) else { return currentRevision(forSessionID: sessionID) }
        var reader = readers[sessionID]
        if reader?.path != source.transcriptPath || reader?.agentKind != source.agentKind {
            reader = AgentSessionSearchTranscript(path: source.transcriptPath, agentKind: source.agentKind)
            revisions[sessionID] = nil
        }
        guard let reader else { return nil }

        readsInFlight.insert(sessionID)
        defer { readsInFlight.remove(sessionID) }
        let readQueue = self.readQueue
        let (refreshed, changed) = await withCheckedContinuation { continuation in
            readQueue.async {
                var next = reader
                let changed = next.refresh()
                continuation.resume(returning: (next, changed))
            }
        }
        if changed || revisions[sessionID] == nil {
            revisions[sessionID] = nextRevision
            nextRevision += 1
        }
        readers[sessionID] = refreshed
        return currentRevision(forSessionID: sessionID)
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
