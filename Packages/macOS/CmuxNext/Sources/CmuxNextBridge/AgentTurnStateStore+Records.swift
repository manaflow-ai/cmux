public import CmuxNextDaemon
import Foundation
import Observation
import os

/// The store's records (``AgentTurnStateStore/sessions``): only the watch's writes make one, a read of
/// a session with no record answers the defaults, and a record leaves when its chat ends on its acpmux or,
/// past ``AgentTurnStateStore/recordCap``, when it is among the idle ones written longest ago.
extension AgentTurnStateStore {
    /// How many sessions the store holds a record of (debug reads and tests).
    public var recordCount: Int { sessions.count }

    /// The record of `session` for a write of the watch, made empty on first use. Only writes
    /// call it: a read of a session with no record answers the defaults (``existing(_:)``), so
    /// reading N unknown ids leaves the store as it was.
    func record(_ session: String) -> Session {
        writes &+= 1
        if let record = sessions[session] {
            record.lastWrite = writes
            return record
        }
        let record = Session()
        record.lastWrite = writes
        sessions[session] = record
        // Only the readers that waited for this session hear it (``awaited``), never every record-less reader.
        if let signal = awaited.removeValue(forKey: session) { signal.made &+= 1 }
        if sessions.count > recordCap { dropIdleRecords() }
        return record
    }

    /// The record of `session` for a read; nil when there is none, after observing that session's own signal
    /// (``awaited``) so the reader reads again once the watch writes it, and on no other session's first write.
    func existing(_ session: String) -> Session? {
        if let record = sessions[session] { return record }
        let signal = awaited[session] ?? {
            let made = AgentTurnRecordSignal()
            awaited[session] = made
            return made
        }()
        _ = signal.made
        return nil
    }

    private func local(_ ref: AgentSessionRef) -> Session? {
        guard let session = ref.session, isMirrored(ref.host) else { return nil }
        return existing(session)
    }

    /// Past ``recordCap``: the idle records (no turn running or waiting, no unread end, no
    /// subagent or command running) written longest ago go, down to seven eighths of the cap, so
    /// this runs once per cap/8 new records. Logged with the counts: no real list is this long.
    private func dropIdleRecords() {
        let before = sessions.count
        let target = recordCap - recordCap / 8
        let idle = sessions.filter { $0.value.state == nil && !AgentTurnState.isWorking(nil, detail: $0.value.detail) }
            .sorted { $0.value.lastWrite < $1.value.lastWrite }
        let dropped = idle.prefix(max(0, before - target))
        for (id, _) in dropped { forget(id) }
        logger.error("agent turn states: \(before, privacy: .public) records past the cap of \(self.recordCap, privacy: .public); dropped the \(dropped.count, privacy: .public) idle ones written longest ago")
    }

    /// Drops `id`'s record. Its readers observed its facts, not the dictionary: each fact goes
    /// back to empty first (what a purge's push wrote before), so a tab that showed it redraws.
    private func forget(_ id: String) {
        guard let record = sessions.removeValue(forKey: id) else { return }
        if record.state != nil {
            if record.state == .working { workingSessions -= 1 } // the count stays this Mac's working records
            record.state = nil
            stateRevision &+= 1
        }
        if record.lastMessage != nil { record.lastMessage = nil }
        if record.muted { record.muted = false }
        if record.title != nil { record.title = nil }
        if record.generatedTitle != nil { record.generatedTitle = nil }
        if record.sessionName != nil { record.sessionName = nil }
        if record.identity != nil {
            record.identity = nil
            record.iconArt = nil
        }
        if record.detail != nil { record.detail = nil }
        if !record.peers.isEmpty { record.peers = [:] }
    }

    /// Session `session` ended on its acpmux (deleted, or gone from its watch's whole list): its
    /// record goes, unless an acpmux peer still has a row of that id (that daemon's session).
    public func sessionEnded(_ session: String) {
        guard let record = sessions[session], record.peers.isEmpty else { return }
        forget(session)
    }

    /// Whether a chat of `host` has its facts here: this Mac's or a mirrored acpmux's.
    private func isMirrored(_ host: String) -> Bool {
        host == localHost || mirroredHosts.contains(host)
    }

    // MARK: Reads

    /// Each acpmux peer's row of session id `session` (chats of other machines), by peer.
    public func peerRows(_ session: String) -> [String: AgentPeerRow] { sessions[session]?.peers ?? [:] }

    /// The turn state of the session an agent chat tab shows.
    public func state(for ref: AgentSessionRef) -> AgentTurnState? { local(ref)?.state }

    /// Whether the chat `ref` shows runs a turn now: by this Mac's (or a mirrored acpmux's) state, else, for a chat of
    /// another machine, by the row this Mac's acpmux has of it from the acpmux peer `isChatMachine` says is the chat's
    /// machine, when that row is live (a stale row's state is only the last one seen). Another peer's row of the same
    /// session id is another daemon's session.
    public func isWorking(_ ref: AgentSessionRef, isChatMachine: (_ peer: String) -> Bool) -> Bool {
        if let record = local(ref) { return record.state == .working }
        guard let session = ref.session else { return false }
        return existing(session)?.peers.values.contains { $0.state == .working && !$0.stale && isChatMachine($0.name) } ?? false
    }

    /// The last message of the session an agent chat tab shows.
    public func lastMessage(for ref: AgentSessionRef) -> String? { local(ref)?.lastMessage }
    /// The last message of `session` as any watch wrote it, this Mac's or an acpmux peer's chat (the
    /// records are keyed by session id): the Chief pet's chat (Show in Mini) may run on a peer.
    public func lastMessage(session: String) -> String? { sessions[session]?.lastMessage }

    /// The recent moments of the chat an agent chat tab shows (u3320); empty off this Mac.
    public func timeline(for ref: AgentSessionRef) -> AgentTimeline {
        guard let session = ref.session, isMirrored(ref.host) else { return AgentTimeline() }
        return sessions[session]?.timeline ?? AgentTimeline()
    }

    /// The model and running turn of the chat an agent chat tab shows; nil off this Mac.
    public func detail(for ref: AgentSessionRef) -> AgentChatDetail? { local(ref)?.detail }

    /// The title of the chat an agent chat tab shows; nil when it has none yet or is not on
    /// this Mac.
    public func title(for ref: AgentSessionRef) -> String? { local(ref)?.title }

    /// The launcher/session name, when it is user-readable.
    public func sessionName(for ref: AgentSessionRef) -> String? { local(ref)?.sessionName }

    /// The chat's real title, excluding its session name and first prompt.
    public func generatedTitle(for ref: AgentSessionRef) -> String? { local(ref)?.generatedTitle }

    /// The name given to the session `ref` shows (acpmux `displayName`); nil when none was, or off this Mac.
    public func displayName(for ref: AgentSessionRef) -> String? { local(ref)?.identity?.displayName }

    /// Every name that session had before its current one, oldest first (acpmux `formerNames`).
    public func formerNames(for ref: AgentSessionRef) -> [String] { local(ref)?.identity?.formerNames ?? [] }

    /// The name that session had just before its current one (the newest of `formerNames`).
    public func formerName(for ref: AgentSessionRef) -> String? { local(ref)?.identity?.formerName }

    /// The icon that session set for itself, drawn once per icon (``HarnessIconArtwork/art(_:)``, the harness
    /// icons' drawing); nil when it set none or cannot be drawn.
    func iconArt(for ref: AgentSessionRef) -> HarnessIconLookup.Art? {
        guard let record = local(ref), let spec = record.identity?.icon else { return nil }
        if let drawn = record.iconArt { return drawn }
        let drawn = HarnessIconArtwork.art(spec)
        record.iconArt = .some(drawn)
        return drawn
    }

    /// Whether the chat an agent chat tab shows has its notifications muted; nil when
    /// the chat is not on this Mac (its acpmux runs elsewhere) or not known yet.
    public func isMuted(_ ref: AgentSessionRef) -> Bool? { local(ref)?.muted }
}

extension AgentTurnStateStore.Session {
    /// Nothing is known of the session: every fact is empty, so dropping the record changes
    /// nothing a reader sees.
    var isBlank: Bool {
        state == nil && peers.isEmpty && lastMessage == nil && !muted && title == nil && generatedTitle == nil
            && sessionName == nil && identity == nil && detail == nil && startedBy == nil && timeline.events.isEmpty
    }
}

/// Fires when one session gets its first record (``AgentTurnStateStore/awaited``).
@Observable @MainActor
final class AgentTurnRecordSignal {
    var made: UInt64 = 0
}
