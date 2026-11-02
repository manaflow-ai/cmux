public import Foundation
import os
import CmuxNextCompat

/// The prompts the person sent from an agent pane that acpmux has not acknowledged yet, kept in a
/// file so they outlive the app: a crash, a quit or an update relaunch between the send and
/// acpmux's acknowledgement no longer loses the prompt. The pane cannot keep them itself: its web
/// data store does not survive a relaunch (``AgentPaneView``'s shared store is non-persistent).
///
/// - The relay records a `session/prompt` after every page rule passed it and before it goes out
///   (``AgentPaneTransport``), and forgets it at acpmux's `_acpmux/prompt_accepted` for its
///   promptId or at the reply to its request (a result, a `duplicate` or an error).
/// - Entries of an earlier run, and those of a connection the host closed, are left over: the next
///   connection to the same daemon on this Mac claims them and sends each again, once, with
///   `_meta.acpmux.resend` and the same promptId (``claimLeftovers(daemon:owner:)``). acpmux runs a
///   prompt id at most once: its ledger and its session log answer one it has seen as `duplicate`.
/// - A connection the daemon closed while the app runs drops the prompts its page sent: the pane
///   shows each as not sent, with Retry, so the pane owns them from then on.
/// - An entry older than ``maximumAge`` is dropped, never sent. The file holds at most
///   ``maximumEntries``; a prompt larger than ``maximumParamsBytes`` is not kept.
///
/// The host sends again only what it recorded from a frame the page rules let through; the page
/// can never set `resend` itself (``AcpmuxPaneMethods/knownParams``). The pane's Retry sends a
/// prompt again under its promptId: the relay marks that a resend when it sent the id to the same
/// daemon before in this run (``sendsAgain(daemon:promptId:)``). Chats on another machine are
/// not kept (their daemon is not this Mac's). The file is read once and written in order, never
/// on the main thread; a record is on disk before its frame is sent.
public nonisolated final class AgentPanePromptJournal: Sendable {
    /// How long a prompt may wait for its send again; an older one is dropped.
    public static let maximumAge: TimeInterval = 24 * 60 * 60
    static let maximumEntries = 64
    static let maximumParamsBytes = 8 << 20
    static let fileName = "agent-pane-unsent-prompts.json"

    /// The app's journal: `<Application Support>/<bundle id>/agent-pane-unsent-prompts.json`. Nil
    /// outside an app bundle (package tests, tools), so they never write the app's file.
    public static let shared: AgentPanePromptJournal? = {
        guard Bundle.main.bundleURL.pathExtension == "app", let bundle = Bundle.main.bundleIdentifier, !bundle.isEmpty,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return AgentPanePromptJournal(url: support.appending(path: bundle).appending(path: fileName))
    }()

    /// One prompt waiting for acpmux's acknowledgement.
    nonisolated struct Entry: Codable, Sendable, Equatable {
        /// The acpmux unix socket the prompt went to: its daemon, across that daemon's restarts.
        var daemon: String
        var sessionId: String
        var promptId: String
        /// The frame's params as the relay sent them (the fresh serialization of the checked frame).
        var params: String
        var at: Date
    }

    nonisolated struct PendingTrust: Codable, Sendable, Equatable {
        var daemon: String
        var folder: String
    }

    private nonisolated struct Document: Codable {
        var version = 2
        var entries: [Entry]
        var pendingTrust: [PendingTrust]

        init(entries: [Entry], pendingTrust: [PendingTrust]) {
            self.entries = entries
            self.pendingTrust = pendingTrust
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            entries = try values.decode([Entry].self, forKey: .entries)
            pendingTrust = try values.decodeIfPresent([PendingTrust].self, forKey: .pendingTrust) ?? []
        }
    }

    /// Who holds an entry in this run: the connection (its relay's token) whose page sent it, or
    /// the one that sends it again. An entry nobody holds is left over.
    private nonisolated enum Holder: Equatable {
        case page(UUID)
        case resend(UUID)

        var owner: UUID {
            switch self {
            case .page(let owner), .resend(let owner): owner
            }
        }
    }

    private nonisolated struct State {
        var loaded = false
        var entries: [Entry] = []
        var pendingTrust: [PendingTrust] = []
        var holders: [String: Holder] = [:]
        /// Connections that ended: they record and claim nothing more.
        var ended: Set<UUID> = []
        /// The daemon and promptId of each prompt the relay sent in this run (never on disk). Never
        /// trimmed: a failed row keeps its Retry for the whole run, and a forgotten id would go
        /// unmarked. One person's prompts in one run stay small.
        var sent: Set<String> = []
        var generation = 0
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.prompt-journal")
    let url: URL
    let now: @Sendable () -> Date
    private let state = Mutex(State())
    /// The newest generation on disk; a write of an older one is skipped.
    private let written = Mutex(0)
    /// The journal on disk could not be read and could not be moved aside yet: nothing is written
    /// over it until a move works.
    private let unreadableKept = Mutex(false)
    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.agent-pane.prompt-journal", qos: .utility)

    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    private static func key(_ daemon: String, _ promptId: String) -> String { daemon + "\u{0}" + promptId }

    /// Records a prompt the page sent on connection `owner`, on disk before it returns. Call off
    /// the main thread. False when it is not kept (too large, or the connection ended).
    func record(_ entry: Entry, owner: UUID) -> Bool {
        guard entry.params.utf8.count <= Self.maximumParamsBytes else {
            Self.logger.info("agent pane prompt not journaled: too large")
            return false
        }
        var kept = false
        change { state in
            guard !state.ended.contains(owner) else { return false }
            let key = Self.key(entry.daemon, entry.promptId)
            state.entries.removeAll { Self.key($0.daemon, $0.promptId) == key }
            state.entries.append(entry)
            state.holders[key] = .page(owner)
            while state.entries.count > Self.maximumEntries {
                let dropped = state.entries.removeFirst()
                state.holders[Self.key(dropped.daemon, dropped.promptId)] = nil
            }
            kept = true
            return true
        }
        return kept
    }

    /// Trust I/O uses the journal's file queue, never the main actor or cooperative task pool.
    func trustIO<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in queue.async { done.resume(returning: work()) } }
    }

    /// Persists a folder whose trust write must complete before journal replay. An empty daemon is
    /// used when a native picker completed before this pane had opened its socket; the next local
    /// connection adopts that barrier.
    func recordPendingTrust(daemon: String?, folder: String) -> Bool {
        let key = daemon ?? ""
        return change { state in
            if !key.isEmpty { state.pendingTrust.removeAll { $0.daemon.isEmpty && $0.folder == folder } }
            if !state.pendingTrust.contains(where: { $0.daemon == key && $0.folder == folder }) {
                state.pendingTrust.append(PendingTrust(daemon: key, folder: folder))
            }
            return true // Retry persistence even if a previous write failed.
        }
    }

    /// The first local connection claims picks made before a daemon was known, durably.
    func bindPreOpenTrust(daemon: String) -> Bool {
        change { state in
            guard !state.pendingTrust.isEmpty else { return false }
            for index in state.pendingTrust.indices where state.pendingTrust[index].daemon.isEmpty {
                state.pendingTrust[index].daemon = daemon
            }
            return true
        }
    }

    /// Pending trust barriers for a local daemon, including a pre-open native pick.
    func pendingTrustFolders(daemon: String) -> [String] {
        state.withLock { state in
            load(&state)
            return state.pendingTrust.filter { $0.daemon.isEmpty || $0.daemon == daemon }.map(\.folder)
        }
    }

    /// Clears a barrier only after acpmux acknowledged the trust write.
    func clearPendingTrust(daemon: String?, folder: String) {
        let key = daemon ?? ""
        change { state in
            let before = state.pendingTrust.count
            state.pendingTrust.removeAll { $0.folder == folder && $0.daemon == key }
            return state.pendingTrust.count != before
        }
    }

    /// Notes that the relay sends prompt `promptId` to `daemon`. True when it sent that id there
    /// before in this run: the pane's Retry, which goes as a resend.
    func sendsAgain(daemon: String, promptId: String) -> Bool {
        state.withLock { !$0.sent.insert(Self.key(daemon, promptId)).inserted }
    }

    /// acpmux acknowledged or answered the prompt, or it never went: it is not sent again. On disk
    /// before it returns, so a record of the same promptId after it is never undone; call off the
    /// main thread.
    func forget(daemon: String, promptId: String) {
        change { state in
            let key = Self.key(daemon, promptId)
            state.holders[key] = nil
            let before = state.entries.count
            state.entries.removeAll { Self.key($0.daemon, $0.promptId) == key }
            return state.entries.count != before
        }
    }

    /// The left-over prompts for `daemon`, now held by connection `owner`, which sends each again.
    /// Expired ones are dropped. Call off the main thread.
    func claimLeftovers(daemon: String, owner: UUID) -> [Entry] {
        var claimed: [Entry] = []
        change { state in
            guard !state.ended.contains(owner) else { return false }
            let cutoff = now().addingTimeInterval(-Self.maximumAge)
            let before = state.entries.count
            state.entries.removeAll { $0.at < cutoff }
            for entry in state.entries where entry.daemon == daemon {
                let key = Self.key(entry.daemon, entry.promptId)
                guard state.holders[key] == nil else { continue }
                state.holders[key] = .resend(owner)
                claimed.append(entry)
            }
            return state.entries.count != before
        }
        return claimed
    }

    /// Claimed prompts connection `owner` did not send after all: left over again.
    func unclaim(_ entries: [Entry], owner: UUID) {
        state.withLock { state in
            for entry in entries where state.holders[Self.key(entry.daemon, entry.promptId)] == .resend(owner) {
                state.holders[Self.key(entry.daemon, entry.promptId)] = nil
            }
        }
    }

    /// Connection `owner` ended. `byDaemon`: the daemon's side closed it, and its page was told,
    /// so the prompts that page sent are the page's again (Retry); the rest are left over. The
    /// change is made at once (no file read on the caller's thread) and written off it.
    func connectionEnded(owner: UUID, byDaemon: Bool) {
        let snapshot = state.withLock { state -> (Int, [Entry], [PendingTrust])? in
            state.ended.insert(owner)
            guard state.loaded else { return nil }
            var changed = false
            for (key, holder) in state.holders where holder.owner == owner {
                state.holders[key] = nil
                if byDaemon, case .page = holder {
                    state.entries.removeAll { Self.key($0.daemon, $0.promptId) == key }
                    changed = true
                }
            }
            guard changed else { return nil }
            state.generation += 1
            return (state.generation, state.entries, state.pendingTrust)
        }
        guard let (generation, entries, pendingTrust) = snapshot else { return }
        queue.async { [self] in write(entries, pendingTrust: pendingTrust, generation: generation) }
    }

    /// The prompts kept now (tests).
    func entries() -> [Entry] {
        state.withLock { state in
            load(&state)
            return state.entries
        }
    }

    /// Returns once every queued write so far is on disk (tests).
    func settle() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    /// `body` reports mutation; the return value reports persistence success. No mutation is a
    /// successful no-op, so opening an empty journal never fails its trust barrier.
    @discardableResult
    private func change(_ body: (inout State) -> Bool) -> Bool {
        let snapshot = state.withLock { state -> (Int, [Entry], [PendingTrust])? in
            load(&state)
            guard body(&state) else { return nil }
            state.generation += 1
            return (state.generation, state.entries, state.pendingTrust)
        }
        guard let (generation, entries, pendingTrust) = snapshot else { return true }
        return write(entries, pendingTrust: pendingTrust, generation: generation)
    }

    /// Reads the file once; an unreadable one is set aside (kept beside it) and the journal starts empty.
    private func load(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else {
            setAsideUnreadableFile()
            return
        }
        guard let document = try? Self.decoder.decode(Document.self, from: data) else {
            setAsideUnreadableFile()
            Self.logger.error("agent pane prompt journal unreadable; set aside, starting empty")
            return
        }
        state.entries = Array(document.entries.suffix(Self.maximumEntries))
        state.pendingTrust = document.pendingTrust
    }

    /// Preserve an existing journal when its bytes cannot be read or decoded; a later write must
    /// never overwrite the only copy of prompts waiting for acknowledgement. A move that fails leaves
    /// `unreadableKept` set: every write tries the move again first, and writes nothing until it works.
    private func setAsideUnreadableFile() {
        unreadableKept.withLock { kept in kept = !moveUnreadableFileAside() }
    }

    /// Moves the file beside itself; true when it is gone from `url` (moved, or no longer there).
    private func moveUnreadableFileAside() -> Bool {
        let files = FileManager.checked
        guard files.fileExists(atPath: url.path) else { return true }
        let aside = url.deletingPathExtension()
            .appendingPathExtension("unreadable-\(Int(now().timeIntervalSince1970))")
            .appendingPathExtension(url.pathExtension)
        do {
            try files.moveItem(at: url, to: aside)
            return true
        } catch {
            Self.logger.error("agent pane prompt journal unreadable and not set aside; not overwritten: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func write(_ entries: [Entry], pendingTrust: [PendingTrust], generation: Int) -> Bool {
        written.withLock { last in
            guard generation > last else { return true }
            // An unreadable journal still in place is never written over (setAsideUnreadableFile).
            let blocked = unreadableKept.withLock { kept in
                if kept { kept = !moveUnreadableFileAside() }
                return kept
            }
            if blocked { return false }
            do {
                let data = try Self.encoder.encode(Document(entries: entries, pendingTrust: pendingTrust))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
                last = generation
                return true
            } catch {
                Self.logger.error("agent pane prompt journal write failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
