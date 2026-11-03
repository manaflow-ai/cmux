public import CmuxNextDaemon
import CmuxNextCompat
import CmuxNextSettings
import Foundation

/// The agent pane's side of the machine-state feed (Leo, 2026-10-28: "you just get a little green
/// dot ... as if you were working on your own computer, but now it's remote"). A chat on another
/// machine gets that machine's link for the composer strip's dot (`machineLink`), the sidebar
/// header's same word (the App's ``state``), so the strip and the sidebar never disagree; and
/// using a machine whose link is down reconnects it (``reconnecting(machine:)``). The App owns one
/// (`AgentTabStore`) and hands it to each pane's model. Not an AgentPaneView extension: that type
/// is at its size limit.
public final class AgentPaneMachineLink {
    /// One pane's machine link: `link` is `connected`, `connecting`, `offline`, `paused` or
    /// `attention` (the sidebar's `MachineLinkState`); `words` says it ("Reconnecting…").
    public nonisolated struct State: Equatable, Sendable {
        public var machine: String
        public var link: String
        public var words: String

        public init(machine: String, link: String, words: String) {
            self.machine = machine
            self.link = link
            self.words = words
        }

        var json: CmuxNextSettings.JSONValue { ["machine": .string(machine), "link": .string(link), "words": .string(words)] }
    }

    /// What a chat that needs a machine finds its link doing.
    public nonisolated enum Use: Sendable {
        /// Its handshake finished: a failure was not the link's.
        case up
        /// Connecting or reconnecting on its own: wait for it.
        case coming
        /// Dropped or never came up: reconnect it, then wait.
        case down
        /// A person must act first (sign-in, an update), or the machine is unknown.
        case stuck
    }

    /// The link of the machine `view`'s chat runs on, read through Observation (the App reads its
    /// machine registry); nil for a chat on this Mac.
    public var state: @MainActor (AgentPaneView) -> State? = { _ in nil } {
        didSet { restart() }
    }
    /// What machine `id`'s link is doing now, read through Observation.
    public var use: @MainActor @Sendable (String) -> Use = { _ in .stuck }
    /// Runs the machine header's own Reconnect on machine `id`.
    public var reconnect: @MainActor (String) -> Void = { _ in }
    /// How long a chat waits for its machine to come back before its call fails as it did.
    public var budget: Duration = .seconds(45)

    /// The pages pushed so far, held weakly, for the pushes on a change.
    private let views = NSHashTable<AgentPaneView>.weakObjects()
    private var observation: Task<Void, Never>?
    /// How many chats wait on each machine's link now: only the first runs its Reconnect.
    private var waiting: [String: Int] = [:]

    public init() {}

    /// The link, read now, as a page host event; `view` then also gets every change.
    func event(for view: AgentPaneView) -> AgentPageEvent {
        if !views.contains(view) {
            views.add(view)
            // The new page's machine joins what the observation reads.
            restart()
        }
        return Self.event(state(view))
    }

    /// `view`'s page no longer gets the link (its tab released it); the last page gone ends the
    /// observation.
    public func forget(_ view: AgentPaneView) {
        guard views.contains(view) else { return }
        views.remove(view)
        restart()
    }

    static func event(_ state: State?) -> AgentPageEvent {
        AgentPageEvent(kind: "machineLink", value: state?.json ?? .null)
    }

    private func send(_ state: State?, to view: AgentPaneView) {
        let event = Self.event(state)
        view.deliver([event], scripts: [])
    }

    private func restart() {
        observation?.cancel()
        observation = nil
        guard views.count > 0 else { return }
        // task-owner: the App's tab store (app lifetime); event-driven (Observation on the
        // machines' link state). Cancelled when it is restarted (a page joins or is forgotten,
        // `state` is set) and not restarted once no page is left (``forget(_:)``);
        // also ends at the next change once this instance or its pages are gone (held weakly).
        observation = Task { [weak self] in
            var last: [ObjectIdentifier: State?] = [:]
            let reads = ObservationStream { [weak self] () -> [(AgentPaneView, State?)] in
                guard let self else { return [] }
                return views.allObjects.map { ($0, state($0)) }
            }
            for await pages in reads {
                guard let self, !pages.isEmpty else { return }
                for (view, state) in pages where last[ObjectIdentifier(view)] != .some(state) {
                    // Pushed again after a restart too: the value is the whole state, so a repeat changes nothing.
                    last[ObjectIdentifier(view)] = .some(state)
                    send(state, to: view)
                }
            }
        }
    }

    // MARK: - Reconnect on use

    /// The attach client's ``AgentSessionAttachClient/Reconnect`` for a chat on machine `machine`:
    /// a connection that fails (its endpoint, its socket or its handshake) reconnects the machine
    /// when its link is down and tries once more, so the send the person made goes out once the
    /// handshake finished, with no Reconnect or Retry click.
    public nonisolated func reconnecting(machine: String) -> AgentSessionAttachClient.Reconnect {
        let wait: @MainActor @Sendable (String) async -> Bool = { [weak self] machine in await self?.awaitLink(machine) ?? false }
        return { await wait(machine) }
    }

    /// Reconnects `machine` when its link is down (``reconnect``) and waits up to ``budget`` for
    /// its handshake; true once it finished. A machine on its way is only waited for. Stops on the
    /// handshake, a link that needs a person (`stuck`: a refused sign-in, a required update), the
    /// deadline or the caller's cancellation (structured: a cancelled send stops waiting at once
    /// and is not retried). Chats waiting on one machine run one Reconnect.
    func awaitLink(_ machine: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        let first = waiting[machine] == nil
        switch use(machine) {
        case .up, .stuck: return false
        case .coming: break
        case .down: if first { reconnect(machine) }
        }
        waiting[machine, default: 0] += 1
        defer {
            let left = (waiting[machine] ?? 1) - 1
            waiting[machine] = left > 0 ? left : nil
        }
        let use = use
        let back = await Self.settles(within: budget) { () -> Bool? in
            switch use(machine) {
            case .up: true
            case .stuck: false
            case .coming, .down: nil
            }
        }
        return back && !Task.isCancelled
    }

    /// The first answer `settled` gives (nil: not yet) within `limit`, else false: an observation,
    /// bounded by a one-shot deadline.
    private static func settles(within limit: Duration, _ settled: @escaping @MainActor @Sendable () -> Bool?) async -> Bool {
        if let answer = settled() { return answer }
        // concurrency-allow: the observation task exits on cancellation; this bounds a machine link's return
        return await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await answer in ObservationStream({ settled() }) { if let answer { return answer } }
                return false
            }
            group.addTask {
                // wakeup-allow: one-shot deadline for a machine link to come back
                try? await Task.sleep(for: limit)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }
}
