import AppKit
package import CmuxNextHibernation
package import CmuxNextWakeups

/// A cmux page the lifecycle drives (``PageWebViewLifecycle`` for a ``PageWebView``).
@MainActor
package protocol PageLifecycleTarget {
    /// The page object: its identity, and nil once it is gone (the lifecycle then forgets it).
    var object: AnyObject? { get }
    /// The page's renderer group (``PageProcessGroup``'s raw value), passed through to the plan.
    var lifecycleGroup: String? { get }
    /// What the page itself knows keeps it (loading, focused), read once per planner pass.
    var lifecycleKeepReasons: Set<PageLifecyclePlanner.KeepReason> { get }
    /// From now on the page calls ``PageLifecycle/pageReasonsDidChange(_:)`` when a reason it reports
    /// starts or ends with no show or hide (its load). Called once per page object.
    func reportsReasonChanges(to lifecycle: PageLifecycle)
    /// Hidden to frozen: no task, timer or frame runs; the page keeps its memory.
    func freeze()
    /// Back to running, in the turn of the show and before the page is visible: after a freeze it
    /// resumes, after a discard it loads again behind its picture. Does nothing on a running page.
    func thaw()
    /// Hidden or frozen to discarded: the document goes, the shell keeps route, state and picture.
    func discard()
}

/// A ``PageWebView`` as the lifecycle drives it. Freeze, and thaw of a frozen page, are no-ops until
/// p13-webui-028 (Chromium SetPageFrozen, WebKit hidden in its window); the discard ends the document
/// and thaw brings a discarded page back behind its snapshot (PageWebView+Discard.swift).
package struct PageWebViewLifecycle: PageLifecycleTarget {
    package private(set) weak var view: PageWebView?

    package init(_ view: PageWebView) { self.view = view }

    package var object: AnyObject? { view }

    package var lifecycleGroup: String? { view?.descriptor.processGroup.rawValue }

    /// Loading while its document loads (``PageLoadState``: Chrome's kLoading reads the
    /// page's loading state, which also ends while the page is hidden), and focused while it holds its
    /// window's first responder.
    package var lifecycleKeepReasons: Set<PageLifecyclePlanner.KeepReason> {
        guard let view else { return [] }
        var reasons: Set<PageLifecyclePlanner.KeepReason> = []
        if view.loadState.isLoading { reasons.insert(.loading) }
        if let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: view) { reasons.insert(.focused) }
        return reasons
    }

    package func reportsReasonChanges(to lifecycle: PageLifecycle) { view?.loadState.lifecycle = lifecycle }

    package func freeze() {}
    package func thaw() { view?.restoreDiscardedPage() }
    package func discard() { view?.discardPage() }
}

/// The page lifecycle controller (plans/cmux-next/chrome-parity/p13-webui.md 3.C): it takes each
/// cmux page's show and hide from the tab content lifecycle (`TabContentCache+Lifecycle`, the one
/// visibility source) and performs ``PageLifecyclePlanner``'s plan on the pages: Active, Hidden,
/// Frozen, Discarded.
///
/// Chrome's freezing policy works the same way (components/performance_manager/freezing/
/// freezing_policy.cc): page nodes report visibility and loading state to one policy, which freezes
/// a page once no `CannotFreezeReason` holds and unfreezes it when it shows or a reason appears. As
/// there, nothing here observes a page: a show or hide is one call from the content lifecycle, a load
/// that starts or ends is one call from the page (``pageReasonsDidChange(_:)``), and each is O(1);
/// the planner runs only at the next deadline, on the hidden pages, from one one-shot
/// ``MainDeadline`` in the background class (nobody sees hidden pages). A show thaws in its own turn,
/// before the content lifecycle reveals the page.
///
/// ```swift
/// lifecycle.hide(key, page: PageWebViewLifecycle(view))   // the tab's conceal
/// lifecycle.show(key, page: PageWebViewLifecycle(view))   // the tab's reveal: thaws first
/// ```
@MainActor
package final class PageLifecycle {
    package typealias State = PageLifecyclePlanner.State
    package typealias KeepReason = PageLifecyclePlanner.KeepReason

    private struct Entry {
        var target: any PageLifecycleTarget
        /// The state the target was last put in.
        var state: State = .active
        /// When the page last hid (the scheduler's uptime); nil while shown.
        var hiddenAt: Duration?
        /// The reasons its owners set (``setKeepReasons(_:for:)``).
        var reasons: Set<KeepReason> = []
    }

    private let planner: PageLifecyclePlanner
    package private(set) var conditions: PageLifecyclePlanner.Conditions
    /// The deadline's scheduler, whose clock is the lifecycle's: due times and wakes share it.
    private let deadlines: MainDeadlineScheduler
    private let deadline: MainDeadline
    private var entries: [String: Entry] = [:]
    /// The key of each page object, so a closed view is forgotten without a scan.
    private var keys: [ObjectIdentifier: String] = [:]
    /// Hidden pages, discarded ones included: the only input of a pass. A discarded page keeps its
    /// hidden time, so it keeps the most recently used role (the planner counts it, as Chrome keeps a
    /// discarded tab's PageNode) and that role never moves to an older page because of a discard.
    private var hiddenKeys: Set<String> = []
    /// The page that holds `mostRecentlyUsed`, as the last pass or hide left it; nil when unknown.
    private var mostRecentlyHidden: String?
    /// The uptime of the armed pass (the scheduler's clock), nil when none is armed.
    package private(set) var nextPassAt: Duration?
    /// Runs after each pass (debug trace and tests).
    package var didRunPass: (@MainActor () -> Void)?
    /// The page that tab `key` shows, nil for a tab with no cmux page; the composition root sets it
    /// (page tabs now, agent chats in p13-webui-038). Read by ``tabDidShow(_:)`` and ``tabDidHide(_:)``.
    package var pageOfTab: @MainActor (String) -> (any PageLifecycleTarget)? = { _ in nil }

    /// - Parameters:
    ///   - planner: The pure plan, with its times.
    ///   - conditions: The memory pressure, Low Power Mode and `browser.hibernation` until the first
    ///     ``setConditions(_:)``.
    ///   - deadlines: The app's one deadline scheduler (`AppServices.mainDeadlines`); a test passes one
    ///     on a fake wake-up timer and uptime.
    package init(planner: PageLifecyclePlanner = PageLifecyclePlanner(),
                 conditions: PageLifecyclePlanner.Conditions = .init(),
                 deadlines: MainDeadlineScheduler) {
        self.planner = planner
        self.conditions = conditions
        self.deadlines = deadlines
        deadline = MainDeadline(owner: "webui.lifecycle", workClass: .background, scheduler: deadlines)
    }

    /// `key`'s state as last performed; nil for a page the lifecycle does not know.
    package func state(of key: String) -> State? { entries[key]?.state }

    /// The number of pages the lifecycle knows (debug).
    package var pageCount: Int { entries.count }

    // MARK: Events (each O(1))

    /// The content lifecycle revealed tab `key` (`TabContentCache+Lifecycle`): its page shows. Call
    /// before the view draws; a tab with no cmux page changes nothing.
    package func tabDidShow(_ key: String) {
        if let page = pageOfTab(key) { show(key, page: page) }
    }

    /// The content lifecycle concealed tab `key`: its page hides.
    package func tabDidHide(_ key: String) {
        if let page = pageOfTab(key) { hide(key, page: page) }
    }

    /// `key` shows `page` now. A frozen or discarded page thaws in this call, so the caller reveals
    /// it after.
    package func show(_ key: String, page: any PageLifecycleTarget) {
        guard let object = page.object else { return remove(key) }
        let previous = entries[key]
        let same = previous?.target.object === object
        var entry = adopt(key, page: page, object: object)
        entry.state = .active
        entry.hiddenAt = nil
        entries[key] = entry
        hiddenKeys.remove(key)
        if mostRecentlyHidden == key { mostRecentlyHidden = nil }
        if same, let state = previous?.state, state == .frozen || state == .discarded { page.thaw() }
    }

    /// `key` stopped showing `page`. Arms the pass for when it stops being recently visible, and
    /// for the page that held `mostRecentlyUsed` until now, which may freeze from then on.
    package func hide(_ key: String, page: any PageLifecycleTarget) {
        guard let object = page.object else { return remove(key) }
        // A new view (made again after a discard) runs: it starts hidden, whatever the old one was.
        let replaced = entries[key]?.target.object !== object
        var entry = adopt(key, page: page, object: object)
        let now = uptime()
        if entry.state == .active || replaced {
            entry.state = .hidden
            entry.hiddenAt = now
        }
        entries[key] = entry
        hiddenKeys.insert(key)
        guard entry.state != .discarded else { return }
        let window = Duration.seconds(planner.timing.visibleWindow(lowPowerMode: conditions.lowPowerMode))
        if let previous = mostRecentlyHidden, previous != key, let hiddenAt = entries[previous]?.hiddenAt {
            arm(at: max(now, hiddenAt + window))
        } else if mostRecentlyHidden == nil, hiddenKeys.count > 1 {
            arm(at: now) // whichever page held it is not known: the planner finds it
        }
        mostRecentlyHidden = key
        arm(at: (entry.hiddenAt ?? now) + window)
    }

    /// `key` closed or its page went away: forgotten.
    package func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if let object = entry.target.object { keys[ObjectIdentifier(object)] = nil }
        hiddenKeys.remove(key)
        if mostRecentlyHidden == key { mostRecentlyHidden = nil }
    }

    /// `page` closed (``WebUIHost/close(_:)``): its key is forgotten.
    package func forget(_ page: AnyObject) {
        guard let key = keys[ObjectIdentifier(page)], entries[key]?.target.object === page else { return }
        remove(key)
    }

    /// `page`'s own reasons changed with no show or hide (its load started or ended,
    /// ``PageLoadState``): a hidden page is looked at again now, so a load that ends
    /// while the page is hidden lets it freeze, and one that starts thaws it.
    package func pageReasonsDidChange(_ page: AnyObject) {
        guard let key = keys[ObjectIdentifier(page)], entries[key]?.target.object === page,
              hiddenKeys.contains(key) else { return }
        arm(at: uptime())
    }

    /// The reasons `key`'s owners say keep it (page JS can only add some). A freeze-blocking reason
    /// thaws a frozen page now, as Chrome unfreezes a page that starts to play audio; a dropped
    /// reason arms a pass.
    package func setKeepReasons(_ reasons: Set<KeepReason>, for key: String) {
        guard var entry = entries[key], entry.reasons != reasons else { return }
        let dropped = !entry.reasons.subtracting(reasons).isEmpty
        entry.reasons = reasons
        let thaws = entry.state == .frozen && reasons.contains(where: \.thawsFrozenPage)
        if thaws { entry.state = .hidden }
        entries[key] = entry
        if thaws { entry.target.thaw() }
        if dropped, hiddenKeys.contains(key) { arm(at: uptime()) }
    }

    /// The memory pressure, Low Power Mode, or `browser.hibernation` and its companions changed (the
    /// app's browser hibernation passes on what it follows): a pass looks again.
    package func setConditions(_ conditions: PageLifecyclePlanner.Conditions) {
        guard conditions != self.conditions else { return }
        self.conditions = conditions
        if !hiddenKeys.isEmpty { arm(at: uptime()) }
    }

    // MARK: Pass (at a deadline, O(hidden pages))

    /// Plans the hidden pages and performs the plan; arms the next deadline, if any. The deadline
    /// calls it.
    package func runPass() {
        nextPassAt = nil
        deadline.cancel()
        let now = uptime()
        var pages: [PageLifecyclePlanner.Page] = []
        pages.reserveCapacity(hiddenKeys.count)
        var gone: [String] = []
        for key in hiddenKeys {
            guard let entry = entries[key], entry.target.object != nil, let hiddenAt = entry.hiddenAt else {
                gone.append(key)
                continue
            }
            pages.append(PageLifecyclePlanner.Page(
                key: key, group: entry.target.lifecycleGroup, hiddenFor: Self.seconds(now - hiddenAt),
                keepReasons: entry.reasons.union(entry.target.lifecycleKeepReasons),
                isDiscarded: entry.state == .discarded))
        }
        for key in gone { remove(key) }
        let plan = planner.plan(pages, conditions: conditions)
        mostRecentlyHidden = nil
        for decision in plan.decisions.values {
            perform(decision)
            if decision.keptBy.contains(.mostRecentlyUsed) { mostRecentlyHidden = decision.key }
        }
        if let next = plan.nextCheck { arm(at: now + .seconds(next)) }
        didRunPass?()
    }

    /// Moves one page toward the planned state. A pass only moves pages down (hidden, frozen,
    /// discarded); it thaws a frozen page only for a reason that appeared since
    /// (``PageLifecyclePlanner/KeepReason/thawsFrozenPage``: loading, focus, a setting), never for time
    /// alone: the most recently used one, or a longer recently visible window after Low Power Mode ends.
    private func perform(_ decision: PageLifecyclePlanner.Decision) {
        guard var entry = entries[decision.key], entry.state != decision.state else { return }
        switch (entry.state, decision.state) {
        case (.hidden, .frozen):
            entry.target.freeze()
        case (.hidden, .discarded), (.frozen, .discarded):
            entry.target.discard()
        case (.frozen, .hidden):
            guard decision.keptBy.contains(where: \.thawsFrozenPage) else { return }
            entry.target.thaw()
        default:
            return
        }
        entry.state = decision.state
        entries[decision.key] = entry
    }

    // MARK: Helpers

    private func uptime() -> Duration { deadlines.uptime }

    /// `key`'s entry with `page` as its target; a new page object starts a fresh entry and reports
    /// its reason changes from now on.
    private func adopt(_ key: String, page: any PageLifecycleTarget, object: AnyObject) -> Entry {
        let identity = ObjectIdentifier(object)
        if keys[identity] != key { page.reportsReasonChanges(to: self) }
        guard var entry = entries[key] else {
            keys[identity] = key
            return Entry(target: page)
        }
        if let old = entry.target.object, old !== object { keys[ObjectIdentifier(old)] = nil }
        keys[identity] = key
        entry.target = page
        return entry
    }

    /// Arms the one deadline for `due` unless an earlier one is armed.
    private func arm(at due: Duration) {
        if let armed = nextPassAt, armed <= due { return }
        nextPassAt = due
        let delay = max(.zero, due - uptime())
        deadline.schedule(after: delay) { [weak self] in self?.runPass() }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
