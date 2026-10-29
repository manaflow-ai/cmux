import CmuxNextWakeups

/// Closes of several tabs that wait for pages deciding their own close, so
/// each close stays ONE Reopen Closed step.
///
/// A person's close of several tabs (Close Other Tabs, to the right or left,
/// Close Other Panes) can hold live pages that decide their own close: a
/// Chromium page runs its beforeunload first and closes its tab only
/// afterwards. Lawrence 2026-10-23: "if i close a bunch of tabs with cmd opt t,
/// then cmd shift t, it needs to bring it all back". The other tabs run their
/// local half at once (`prepare`: they leave the strip); their daemon close
/// waits. A page's own close of its tab joins the gesture (``absorb(_:)``)
/// instead of closing alone, and once every page closed, every tab goes in one
/// `send`: one closed group, one Cmd-Shift-T. A page that keeps its tab (Stay)
/// or has not closed by ``deadline`` is left out; the rest is sent then, and
/// that page's later close is its own step.
///
/// `Pane` is the pane that runs a close (compared by identity); `Prepared` is
/// one pane's prepared local half. Tests pass plain classes and closures:
///
/// ```swift
/// let closes = PageDecidedCloses<FakePane, [TabID]>(prepare: { _, ids in ids },
///                                                   send: { prepared, _, _ in sent.append(prepared) })
/// closes.begin(closing: [(pane, ["a"])], deciding: [(pane, ["b"])], userClose: true)
/// _ = closes.absorb([(pane, ["b"])]) // sends [["a"], ["b"]] once
/// ```
@MainActor
public final class PageDecidedCloses<Pane: AnyObject, Prepared> {
    /// Tabs of one pane.
    public typealias Part = (pane: Pane, ids: [TabID])

    private struct Gesture {
        weak var first: Pane?
        var userClose: Bool
        var prepared: [Prepared]
        /// The pages still deciding, by tab.
        var waiting: Set<TabID>
        /// Pages that closed, by pane, in the order they closed.
        var decided: [(pane: WeakPane, ids: [TabID])] = []
        var timer: DemandTimer
    }

    private struct WeakPane {
        weak var pane: Pane?
    }

    private let prepare: @MainActor (Pane, [TabID]) -> Prepared?
    private let send: @MainActor ([Prepared], Pane, Bool) -> Void
    private let clock: any Clock<Duration>
    private var gestures: [Int: Gesture] = [:]
    private var nextID = 0

    /// How long a gesture waits for its pages. A page without a beforeunload
    /// handler closes within a renderer round trip; one that asks waits for
    /// the person, and the other tabs should not.
    public var deadline: Duration = .seconds(2)

    /// Whether a gesture still waits for a page.
    public var isWaiting: Bool { !gestures.isEmpty }

    /// Creates the coordinator.
    ///
    /// - Parameter prepare: Runs a pane's local half of closing tabs (they
    ///   leave its strip) and returns what `send` needs, or nil when nothing
    ///   is left for the daemon.
    /// - Parameter send: Sends prepared halves in one daemon close, from the
    ///   gesture's first pane; the flag says whether a person closed them.
    /// - Parameter clock: The deadline's clock (tests pass their own).
    public init(prepare: @escaping @MainActor (Pane, [TabID]) -> Prepared?,
                send: @escaping @MainActor ([Prepared], Pane, Bool) -> Void,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.prepare = prepare
        self.send = send
        self.clock = clock
    }

    // The isolated deinit of a generic main-actor class crashes the Release optimizer (#23050); the
    // gestures' timers cancel in their own deinit.
    nonisolated deinit {}

    /// Starts a gesture: `closing` run their local half now, `deciding` are
    /// pages that started their own close. Every pane is on one daemon.
    ///
    /// - Parameter closing: Tabs that close at once.
    /// - Parameter deciding: Tabs whose page decides; their close joins later.
    /// - Parameter userClose: Whether a person closed them (passed to `send`).
    public func begin(closing: [Part], deciding: [Part], userClose: Bool) {
        guard let first = (closing.first ?? deciding.first)?.pane else { return }
        let id = nextID
        nextID += 1
        let timer = DemandTimer(owner: "tabs.pageDecidedClose", clock: clock)
        gestures[id] = Gesture(first: first, userClose: userClose, prepared: closing.compactMap { prepare($0.pane, $0.ids) },
                               waiting: Set(deciding.flatMap(\.ids)), timer: timer)
        // The gesture's deadline: pages not closed by then are left out (a page asking its question never holds the rest).
        timer.schedule(after: deadline) { @MainActor [weak self] in self?.finish(id) }
    }

    /// Takes the tabs of `parts` whose page a waiting gesture waits for (the
    /// page closed its tab): they join that gesture's one close.
    ///
    /// - Parameter parts: A close about to run.
    /// - Returns: The tabs no gesture took, which close as usual.
    public func absorb(_ parts: [Part]) -> [Part] {
        guard !gestures.isEmpty else { return parts }
        var rest: [Part] = []
        var done: Set<Int> = []
        for part in parts {
            var kept: [TabID] = []
            for tab in part.ids {
                guard let id = gestures.first(where: { $0.value.waiting.contains(tab) })?.key else { kept.append(tab); continue }
                gestures[id]?.waiting.remove(tab)
                if let index = gestures[id]?.decided.firstIndex(where: { $0.pane.pane === part.pane }) {
                    gestures[id]?.decided[index].ids.append(tab)
                } else {
                    gestures[id]?.decided.append((WeakPane(pane: part.pane), [tab]))
                }
                if gestures[id]?.waiting.isEmpty == true { done.insert(id) }
            }
            if !kept.isEmpty { rest.append((part.pane, kept)) }
        }
        for id in done.sorted() { finish(id) }
        return rest
    }

    /// Sends gesture `id`'s one close: the tabs closed at its start and the
    /// pages that closed since. Pages still deciding are let go.
    private func finish(_ id: Int) {
        guard let gesture = gestures.removeValue(forKey: id) else { return }
        gesture.timer.cancel()
        var prepared = gesture.prepared
        for part in gesture.decided {
            if let pane = part.pane.pane, let half = prepare(pane, part.ids) { prepared.append(half) }
        }
        guard !prepared.isEmpty, let first = gesture.first ?? gesture.decided.lazy.compactMap(\.pane.pane).first else { return }
        send(prepared, first, gesture.userClose)
    }
}
