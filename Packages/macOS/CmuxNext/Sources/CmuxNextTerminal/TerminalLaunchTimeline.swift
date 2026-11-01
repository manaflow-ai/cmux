import CmuxNextCompat
public import Foundation
import CmuxNextWakeups

/// `debug.timings` `launch_terminals` (Debug and bench builds): for each terminal a pane showed at launch, when
/// the pane showed it, the frame showing its saved frame from the last quit committed, the frame of the pass that
/// handed it its first live content committed, and its link to the daemon went live (from then the keys typed in
/// it reach its shell). A quit-and-reopen bench reads it per visible terminal from main()
/// (scripts/journeys/ext_quit.py `quit_speed`). Ghostty draws on its own layer: the live mark is the commit of the
/// pass that queued the content, so the first present can follow it by about a frame.
///
/// The app makes one at launch (`AppServices.launchTerminals`) and hands it to each terminal's view.
/// Takes marks only in the first `window` after it was made and for at most `capacity` terminals, and none in
/// Release builds: it costs nothing after launch.
public nonisolated final class TerminalLaunchTimeline: Sendable {
    /// One terminal's marks; nil until it happened.
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var surface: UInt64
        public var shown: Date
        public var heldFrame: Date?
        public var liveFrame: Date?
        public var linkLive: Date?
    }

    /// What a shown terminal tells its timeline (`TerminalSession.launchMark`).
    enum Mark {
        /// Live content reached its surface.
        case liveContent
        /// Its saved frame from the last quit is shown.
        case savedFrame
    }

    private struct State {
        var entries: [String: Entry] = [:]
        /// Link-live marks by surface: a link can go live before its pane shows it.
        var linkLive: [UInt64: Date] = [:]
    }

    private let state = Mutex(State())
    private let closes: Date
    private let capacity: Int
    private let now: @Sendable () -> Date

    public init(window: TimeInterval = 60, capacity: Int = 128, now: @escaping @Sendable () -> Date = Date.init) {
        closes = now().addingTimeInterval(window)
        self.capacity = capacity
        self.now = now
    }

    /// Whether marks are still taken (Debug and bench builds, inside the launch window).
    public var isOpen: Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        return now() < closes
        #else
        return false
        #endif
    }

    /// A pane shows terminal `key` (its daemon `surface`, its view `session`): the session tells this timeline its
    /// saved frame and its first live content, then stops.
    @MainActor public func shown(key: String, surface: UInt64, session: TerminalSession) {
        guard shown(key: key, surface: surface) else { return }
        session.launchMark = { [weak session, self] mark in
            switch mark {
            case .savedFrame: afterCommit(of: key) { $0.heldFrame = $0.heldFrame ?? $1 }
            case .liveContent:
                // No saved frame shows over live content: nothing more to tell.
                session?.launchMark = nil
                afterCommit(of: key) { $0.liveFrame = $0.liveFrame ?? $1 }
            }
        }
    }

    /// Records that a pane showed `key` (the first time, in the window, under capacity); whether it did. A terminal
    /// with no daemon surface (0: a remote terminal, one still being made) has no link to time: not recorded.
    func shown(key: String, surface: UInt64) -> Bool {
        guard isOpen, surface != 0 else { return false }
        let at = now()
        return state.withLock { state in
            guard state.entries[key] == nil, state.entries.count < capacity else { return false }
            state.entries[key] = Entry(key: key, surface: surface, shown: at, linkLive: state.linkLive[surface])
            return true
        }
    }

    /// `surface`'s link to the daemon went live. Any thread.
    public func linkLive(surface: UInt64) {
        guard isOpen else { return }
        let at = now()
        state.withLock { state in
            guard state.linkLive[surface] == nil, state.linkLive.count < capacity else { return }
            state.linkLive[surface] = at
            for (key, entry) in state.entries where entry.surface == surface && entry.linkLive == nil {
                state.entries[key]?.linkLive = at
            }
        }
    }

    /// An attach observer: `journal` (when it records), plus `timeline`'s link-live mark of `surface` on each event
    /// `live` says made the link live, while it is open. It tests only the event: no work per key.
    public static func observing<Event, Machine>(_ timeline: TerminalLaunchTimeline?, _ journal: (@Sendable (Event, Machine) -> Void)?,
                                                 surface: UInt64, live: @escaping @Sendable (Event, Machine) -> Bool)
        -> (@Sendable (Event, Machine) -> Void)? {
        guard let timeline, timeline.isOpen else { return journal }
        return { event, machine in
            journal?(event, machine)
            if live(event, machine) { timeline.linkLive(surface: surface) }
        }
    }

    /// Records `set` on `key`'s entry with the time this pass's frame committed.
    @MainActor private func afterCommit(of key: String, _ set: @escaping @Sendable (inout Entry, Date) -> Void) {
        guard isOpen else { return }
        AfterFrameCommit().run { [self] in
            let at = now()
            state.withLock { state in
                guard var entry = state.entries[key] else { return }
                set(&entry, at)
                state.entries[key] = entry
            }
        }
    }

    /// The entries, in the order the panes showed them.
    public var entries: [Entry] {
        state.withLock { Array($0.entries.values) }.sorted { ($0.shown, $0.key) < ($1.shown, $1.key) }
    }

    /// Each entry's key and its marks on `clock` (`shown_ms`, `held_frame_ms`, `live_frame_ms`, `link_live_ms`;
    /// a mark that did not happen is absent).
    public func report(_ clock: (Date) -> Double) -> [(key: String, ms: [String: Double])] {
        entries.map { entry in
            let marks: [(String, Date?)] = [("shown_ms", entry.shown), ("held_frame_ms", entry.heldFrame),
                                            ("live_frame_ms", entry.liveFrame), ("link_live_ms", entry.linkLive)]
            return (entry.key, Dictionary(uniqueKeysWithValues: marks.compactMap { name, at in at.map { (name, clock($0)) } }))
        }
    }
}
