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
/// - Entries of an earlier run, and those of a connection that ended (the host closed it, or the
///   daemon did: a restart, a reset socket), are left over: the next connection to the same daemon
///   on this Mac claims them and sends each again, once, with `_meta.acpmux.resend` and the same
///   promptId (``claimLeftovers(daemon:owner:)``). acpmux runs a prompt id at most once: its ledger
///   and its session log answer one it has seen as `duplicate`. The page that lost the prompt with
///   its connection waits for it on the next one (`webviews/.../lostPrompt.ts`) instead of asking
///   the person to send it again.
/// - An entry older than ``maximumAge`` is dropped, never sent. The file holds at most
///   ``maximumEntries``; a prompt larger than ``maximumParamsBytes`` is not kept.
///
/// The host sends again only what it recorded from a frame the page rules let through; the page
/// can never set `resend` itself (``AcpmuxPaneMethods/knownParams``). Chats on another machine are
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

    private nonisolated struct Document: Codable {
        var version = 1
        var entries: [Entry]
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
        var holders: [String: Holder] = [:]
        /// Connections that ended: they record and claim nothing more.
        var ended: Set<UUID> = []
        var generation = 0
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.prompt-journal")
    let url: URL
    let now: @Sendable () -> Date
    private let state = Mutex(State())
    /// The newest generation on disk; a write of an older one is skipped.
    private let written = Mutex(0)
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

    /// Connection `owner` ended, however it ended: the prompts it held are left over for the next
    /// connection. Nothing on disk changes (who holds an entry is this run's memory only).
    func connectionEnded(owner: UUID) {
        state.withLock { state in
            state.ended.insert(owner)
            for (key, holder) in state.holders where holder.owner == owner { state.holders[key] = nil }
        }
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

    /// Applies `body` (true when the entries changed) and writes the result when they did.
    private func change(_ body: (inout State) -> Bool) {
        let snapshot = state.withLock { state -> (Int, [Entry])? in
            load(&state)
            guard body(&state) else { return nil }
            state.generation += 1
            return (state.generation, state.entries)
        }
        guard let (generation, entries) = snapshot else { return }
        write(entries, generation: generation)
    }

    /// Reads the file once; an unreadable one is an empty journal.
    private func load(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        guard let document = try? Self.decoder.decode(Document.self, from: data) else {
            Self.logger.error("agent pane prompt journal unreadable; starting empty")
            return
        }
        state.entries = Array(document.entries.suffix(Self.maximumEntries))
    }

    private func write(_ entries: [Entry], generation: Int) {
        written.withLock { last in
            guard generation > last else { return }
            last = generation
            do {
                let data = try Self.encoder.encode(Document(entries: entries))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
            } catch {
                Self.logger.error("agent pane prompt journal write failed: \(String(describing: error), privacy: .public)")
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
