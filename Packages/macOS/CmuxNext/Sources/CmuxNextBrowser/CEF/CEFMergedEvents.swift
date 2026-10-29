public import CmuxNextWakeups

/// Chromium's high-rate page events, merged per browser per frame (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// section E, task 219). Chrome coalesces a tab's title, URL and load-state invalidations into one UI update
/// (`Browser::ScheduleUIUpdate` and `Browser::ProcessPendingUIUpdates`, chrome/browser/ui/browser.cc); cmux merges to
/// the frame instead of a 200 ms timer, and puts the apply on the main-thread scheduler by the tab's visibility node.
///
/// The address, title, favicon and progress of a browser keep their latest value per kind, and apply in one task:
/// - a visible tab's in its next frame, as `visible` work on its node's queue;
/// - a hidden tab's as `background` work: its progress, which only the tab's own toolbar draws, is held by its node
///   until it shows (or an aligned hidden wake), then applies once; its address, title and icon, which its tab strip
///   item, the sidebar and the session record show while it is hidden, run as one plain background task;
/// - an agent-driven tab's on the next turn as `automation` work: the agent reads its tab's state while it is hidden;
/// - a tab no node follows as `visible` work.
///
/// The class is chosen again each time the node starts or stops rendering: a title that came while the tab was shown
/// and is still held when it hides runs as hidden work, not held until the tab shows again.
///
/// Every other event of a browser (commits, dialogs, crashes, input acknowledgements) stays FIFO and immediate:
/// ``holds(_:for:)`` applies that browser's held events first, so no event overtakes one Chromium sent before it.
/// Chromium sends cmux no status-bubble text yet; it joins ``Kind`` when the shim does.
///
/// ```swift
/// runtime.mergedEvents.work = mainWork            // feature `cefMergedEvents`
/// runtime.mergedEvents.follow(tab, node: tabNode)  // TabContentCache.node(for:)
/// if runtime.mergedEvents.holds(event, for: tab) { return }  // else apply it now
/// ```
final class CEFMergedEvents<Target: AnyObject> {
    /// The kinds merged: each keeps only its latest event per browser.
    nonisolated enum Kind: Sendable {
        case address, title, favicon, progress

        init?(_ event: CEFShimEvent) {
            switch event {
            case .address: self = .address
            case .title: self = .title
            case .favicon: self = .favicon
            case .progress: self = .progress
            default: return nil
            }
        }

        /// Only the tab's own toolbar draws it: a hidden tab's waits for the tab to show.
        var waitsForShow: Bool { self == .progress }
    }

    /// What the merger reads of a target and how it applies an event to it.
    struct Reading {
        /// The browser whose events the target takes now; nil while it has none.
        let browser: (Target) -> Int32?
        /// An agent drives the target: its events run as automation, never held while it is hidden.
        let isAgentDriven: (Target) -> Bool
        /// Applies one merged event, as the runtime applies any event of its browser.
        let apply: (Target, CEFShimEvent) -> Void
    }

    /// The app's one main-thread scheduler (feature `cefMergedEvents`); nil: every event applies at once, as before.
    /// Setting nil applies what is held now.
    var work: MainWorkScheduler? {
        didSet { if work == nil { flushAll() } }
    }

    private let reading: Reading
    private var routes: [ObjectIdentifier: Route] = [:]
    /// Routes of released targets are dropped when the table reaches this size (closed browsers leave at once).
    private var routesPruneAt = 64
    private var held: [Int32: Held] = [:]

    /// The node a target follows, its two queues on the scheduler they were made on, and its rendering flips.
    private final class Route {
        weak var target: Target?
        let node: VisibilityNode
        var rendering: VisibilitySubscription?
        private var made: (work: MainWorkScheduler, visible: MainTaskQueue, background: MainTaskQueue)?

        init(target: Target, node: VisibilityNode) {
            self.target = target
            self.node = node
        }

        nonisolated deinit {}

        func queues(on work: MainWorkScheduler) -> (visible: MainTaskQueue, background: MainTaskQueue) {
            if let made, made.work === work { return (made.visible, made.background) }
            let visible = node.queue(.visible, owner: "CEFMergedEvents", on: work)
            let background = node.queue(.background, owner: "CEFMergedEvents.hidden", on: work)
            made = (work: work, visible: visible, background: background)
            return (visible, background)
        }
    }

    /// A browser's held events, one per kind in the order the kinds first came.
    private struct Held {
        weak var target: Target?
        var events: [CEFShimEvent] = []
        /// The class of the node-free post that applies them; nil while none waits.
        var plainPost: BudgetedWorkClass?

        mutating func merge(_ event: CEFShimEvent, kind: Kind) {
            if let index = events.firstIndex(where: { Kind($0) == kind }) {
                events[index] = event
            } else {
                events.append(event)
            }
        }
    }

    init(reading: Reading) {
        self.reading = reading
    }

    nonisolated deinit {}

    /// Browsers with held events (diagnostics and tests).
    var heldBrowsers: Int { held.count }

    /// `target`'s merged events follow `node` from now; nil: node-free. Held events move to the new node's queues.
    func follow(_ target: Target, node: VisibilityNode?) {
        if routes.count >= routesPruneAt {
            routes = routes.filter { $0.value.target != nil }
            routesPruneAt = max(64, routes.count * 2)
        }
        let id = ObjectIdentifier(target)
        if let node {
            if let route = routes[id], route.target === target, route.node === node { return }
            let route = Route(target: target, node: node)
            route.rendering = node.subscribeRendering(owner: "CEFMergedEvents") { [weak self, weak target] _ in
                if let self, let target { self.renderingChanged(target) }
            }
            routes[id] = route
        } else if routes.removeValue(forKey: id) == nil {
            return
        }
        if let work, let browser = reading.browser(target), held[browser] != nil {
            held[browser]?.plainPost = nil
            schedule(browser, target: target, on: work)
        }
    }

    /// `target`'s browser closed: it follows no node, and nothing of it is held (its close applied what was).
    func forget(_ target: Target, browser: Int32) {
        routes[ObjectIdentifier(target)] = nil
        held[browser] = nil
    }

    /// True: `event` waits for its browser's next merged apply. False: the caller applies it now, and its browser's
    /// held events were applied first (it is no merged kind, or no scheduler or target takes it).
    func holds(_ event: CEFShimEvent, for target: Target?) -> Bool {
        guard let browser = event.browserID else { return false }
        if let work, let kind = Kind(event), let target, reading.browser(target) == browser {
            held[browser, default: Held(target: target)].merge(event, kind: kind)
            schedule(browser, target: target, on: work)
            return true
        }
        if !held.isEmpty, let entry = held.removeValue(forKey: browser) { apply(entry, browser: browser) }
        return false
    }

    /// `target`'s node started or stopped rendering: what its browser holds moves to the class the new state takes.
    private func renderingChanged(_ target: Target) {
        guard let work, let browser = reading.browser(target), held[browser] != nil else { return }
        schedule(browser, target: target, on: work)
    }

    private func flushAll() {
        let all = held
        held = [:]
        for (browser, entry) in all { apply(entry, browser: browser) }
    }

    private func schedule(_ browser: Int32, target: Target, on work: MainWorkScheduler) {
        let agentDriven = reading.isAgentDriven(target)
        let route = agentDriven ? nil : routes[ObjectIdentifier(target)].flatMap { $0.target === target ? $0 : nil }
        let workClass: BudgetedWorkClass
        if let route {
            let shown = route.node.wantsFrames
            if shown || held[browser]?.events.allSatisfy({ Kind($0)?.waitsForShow == true }) == true {
                let queues = route.queues(on: work)
                queues.visible.post(key: browser) { [weak self] in self?.applyHeld(browser) }
                // Hidden: the background queue applies at an aligned hidden wake, the visible one on show; the first wins.
                if !shown { queues.background.post(key: browser) { [weak self] in self?.applyHeld(browser) } }
                return
            }
            workClass = .background
        } else {
            workClass = agentDriven ? .automation : .visible
        }
        guard held[browser]?.plainPost != workClass else { return }
        held[browser]?.plainPost = workClass
        // node-free: a hidden tab's title, icon and address show outside it, an agent reads its hidden tab, and a tab no node follows has nothing to hold it by
        work.post(workClass, owner: "CEFMergedEvents.nodeFree") { [weak self] in self?.applyHeld(browser) }
    }

    private func applyHeld(_ browser: Int32) {
        guard let entry = held.removeValue(forKey: browser) else { return }
        apply(entry, browser: browser)
    }

    private func apply(_ entry: Held, browser: Int32) {
        guard let target = entry.target, reading.browser(target) == browser else { return }
        for event in entry.events { reading.apply(target, event) }
    }
}

extension CEFMergedEvents where Target == CEFTab {
    /// The runtime's: a tab's events apply through ``CEFTab`` as the runtime's own dispatch applies them.
    static func tabs() -> CEFMergedEvents<CEFTab> {
        CEFMergedEvents(reading: Reading(browser: { $0.browserID }, isAgentDriven: { $0.isAgentDriven }, apply: { tab, event in
            #if DEBUG || CMUX_BENCH_HOOKS
            if let browser = tab.browserID { CEFEventTrace.record(browser, event) }
            #endif
            tab.handle(event)
        }))
    }
}

extension CEFEngine {
    /// Feature `cefMergedEvents`: Chromium's address, title, favicon and progress events are
    /// merged per browser per frame on `work` (``CEFMergedEvents``). Nil: every event applies at once, as before.
    ///
    /// - Parameter work: The app's one main-thread scheduler, or nil.
    /// - Returns: This engine.
    @discardableResult
    public func mergingEvents(on work: MainWorkScheduler?) -> CEFEngine {
        CEFRuntime.shared.mergedEvents.work = work
        return self
    }

    /// `page`'s merged events follow `node` from now: applied in the frame while it is visible, as background work
    /// while it is hidden (its progress held until it shows). Nil: node-free. Nothing for a page that is not a
    /// Chromium tab.
    ///
    /// - Parameters:
    ///   - page: A page of this engine.
    ///   - node: The page's tab node (`TabContentCache.node(for:)`).
    public func mergeEvents(of page: any BrowserTab, following node: VisibilityNode?) {
        guard let tab = page as? CEFTab else { return }
        CEFRuntime.shared.mergedEvents.follow(tab, node: node)
    }
}
