package import CmuxNextCompat

/// What the pointer rests on: a tab in a strip, or a workspace row in a window's sidebar
/// (plans/cmux-next/hover-preload-DESIGN.md).
package nonisolated enum HoverWakeTarget: Hashable, Sendable {
    case tab(String)
    case workspace(String, window: String)

    /// The tabs the click would show: the tab, or what `workspaceTabs` resolves for the row's window.
    package func pages(_ workspaceTabs: (_ workspace: String, _ window: String) -> [String]) -> [String] {
        switch self {
        case let .tab(key): [key]
        case let .workspace(id, window): workspaceTabs(id, window)
        }
    }

    /// The cause a restore logs (`prewarm hover`, `prewarm workspace-hover`).
    package var cause: String {
        switch self {
        case .tab: "hover"
        case .workspace: "workspace-hover"
        }
    }
}

/// The dwell that turns a hover into an intent (plans/cmux-next/hover-preload-DESIGN.md). Pure: the
/// gate (`HoverWakeGate`) feeds it the pointer's target and the clock. A target becomes an intent only
/// after it held for `dwell`; a change restarts the dwell, so a sweep (one row per frame) never fires.
/// It fires once per stay: resting on a row longer does not repeat the intent.
package nonisolated struct HoverWakeIntent: Sendable {
    /// What the next timer fire does.
    package nonisolated enum Fire: Equatable, Sendable {
        /// Nothing rests (it left, or the intent for this stay already fired).
        case idle
        /// The target changed within the dwell: fire again after the time left.
        case rearm(Duration)
        /// The target held for the dwell: wake its pages.
        case intent(HoverWakeTarget)
    }

    /// How long the pointer must rest on one target (Chrome's speculation rules wait 200 ms on a link;
    /// a page that is already in memory or has a saved history costs less to start for nothing).
    package static let dwell: Duration = .milliseconds(100)

    package let dwell: Duration
    private(set) var target: HoverWakeTarget?
    private var since: ContinuousClock.Instant?
    /// True while a timer fire is pending: a note then arms nothing.
    private var armed = false
    /// The intent already fired for the current stay.
    private var fired = false

    package init(dwell: Duration = HoverWakeIntent.dwell) {
        self.dwell = dwell
    }

    /// The pointer now rests on `target` (nil: on nothing). Returns the delay to arm the timer with,
    /// or nil when no fire is needed or one is pending already. O(1): no layout, no model.
    package mutating func note(_ target: HoverWakeTarget?, at now: ContinuousClock.Instant) -> Duration? {
        guard target != self.target else { return nil }
        self.target = target
        since = now
        fired = false
        guard target != nil, !armed else { return nil }
        armed = true
        return dwell
    }

    /// Forgets the target and any pending fire (the gate cancelled its timer): the next note arms again.
    package mutating func reset() {
        target = nil
        since = nil
        armed = false
        fired = false
    }

    /// Whether `target` is what the pointer rests on now.
    package func isResting(on target: HoverWakeTarget) -> Bool { self.target == target }

    /// The timer fired at `now`.
    package mutating func fire(at now: ContinuousClock.Instant) -> Fire {
        armed = false
        guard let target, let since, !fired else { return .idle }
        let held = now - since
        guard held >= dwell else {
            armed = true
            return .rearm(dwell - held)
        }
        fired = true
        return .intent(target)
    }
}

/// How many pages one hover intent may wake (plans/cmux-next/hover-preload-DESIGN.md).
package nonisolated struct HoverWakeBudget: Equatable, Sendable {
    /// Hover restores loading at once, at most (Chrome keeps 2 hover prerenders, first in first out).
    package static let inFlight = 2

    /// Pages per intent: 2, 1 under a memory pressure warning or in Low Power Mode, none at critical.
    package let pages: Int

    /// `enabled` false (`browser.keepNeighborTabsAwake` 0) wakes nothing.
    package init(pressure: MemoryPressureLevel, lowPower: Bool, enabled: Bool = true) {
        pages = switch pressure {
        case _ where !enabled: 0
        case .critical: 0
        case .warning: 1
        case .normal: lowPower ? 1 : 2
        }
    }

    /// Of `wanted` restores, how many may start now with `loading` hover restores still loading.
    package func restores(wanted: Int, loading: Int) -> Int {
        max(0, min(wanted, pages, Self.inFlight - loading))
    }
}

/// The tabs a workspace shows when it is selected: the selected tab of each pane on its shown screen, or
/// only the zoomed pane's (plans/cmux-next/hover-preload-DESIGN.md). Pure.
package nonisolated struct HoverWakePanes: Sendable {
    package nonisolated struct Pane: Equatable, Sendable {
        package let id: String
        package let selected: String?
        package init(id: String, selected: String?) {
            self.id = id
            self.selected = selected
        }
    }

    package let panes: [Pane]
    package let zoomed: String?

    package init(_ panes: [Pane], zoomed: String?) {
        self.panes = panes
        self.zoomed = zoomed
    }

    /// The shown tabs in pane order, at most `limit` (past it the budget wakes nothing anyway).
    package func shownTabs(limit: Int = 8) -> [String] {
        let shown = zoomed.flatMap { id in panes.first { $0.id == id }.map { [$0] } } ?? panes
        var keys: [String] = []
        for pane in shown {
            guard let key = pane.selected, !keys.contains(key) else { continue }
            keys.append(key)
            if keys.count == limit { break }
        }
        return keys
    }
}
