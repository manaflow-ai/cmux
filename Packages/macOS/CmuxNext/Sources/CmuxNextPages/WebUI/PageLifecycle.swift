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
    /// The page is hiding: keep its last frame now, while it is still in its window, before the engine
    /// is told it is hidden (the tab's conceal calls the lifecycle first) and before any freeze. A frozen
    /// page cannot answer, so nothing is asked of the page later. Makes no page call.
    func keepHideSnapshot()
    /// The page shows again running (it was hidden or frozen, not discarded): the picture kept at its
    /// hide is out of date.
    func dropHideSnapshot()
    /// Hidden to frozen: no task, timer or frame runs; the page keeps its memory. Returns false when
    /// the page refused (it shows, or its engine did not freeze it): it stays hidden.
    func freeze() -> Bool
    /// Back to running, in the turn of the show and before the page is visible: after a freeze it
    /// resumes, after a discard it loads again behind its picture. Does nothing on a running page.
    func thaw()
    /// Hidden or frozen to discarded: the document goes, the shell keeps route, state and picture.
    /// Makes no call into the page: it uses only what the page gave when it hid, so a frozen page is
    /// discarded on time.
    ///
    /// - Returns: False when the page refused (it shows after all): it keeps its state, and a later
    ///   pass tries again.
    func discard() -> Bool
    /// The page holds an engine page now (its document ran and was not discarded): only then does a
    /// discard free memory, so only then does the app's urgent pass rank it (``PageLifecycle/urgentCandidates()``).
    var holdsEnginePage: Bool { get }
}

extension PageLifecycleTarget {
    /// A target with no engine of its own to ask (a test page) counts as holding one.
    package var holdsEnginePage: Bool { true }
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
/// lifecycle.hide(key, page: PageWebViewLifecycle(view, encoder: encoder))   // the tab's conceal: keeps its last frame
/// lifecycle.show(key, page: PageWebViewLifecycle(view, encoder: encoder))   // the tab's reveal: thaws first
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
        /// A call thawed the page (``thawForCall(_:)``): it keeps ``KeepReason/pageCall`` until then.
        var callThawEnds: Duration?
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
    /// The app's one urgent pass over tabs, chats and pages takes the critical memory event's discard
    /// (feature `memoryUrgentDiscardRanking`, set by the browser hibernation): this lifecycle then
    /// discards nothing until one urgent pace interval after the pressure turns critical, and after
    /// each urgent pass (``urgentPassDidRun()``). Freezes and thaws go on as before.
    package var leavesCriticalEventToUrgentPass = false
    /// Until when (the scheduler's uptime) a pass discards nothing (``leavesCriticalEventToUrgentPass``).
    package private(set) var noDiscardBefore: Duration?
    /// The page that tab `key` shows, nil for a tab with no cmux page; the composition root sets it
    /// (page tabs now, agent chats in p13-webui-038). Read by ``tabDidShow(_:)`` and ``tabDidHide(_:)``.
    package var pageOfTab: @MainActor (String) -> (any PageLifecycleTarget)? = { _ in nil }

    /// - Parameters:
    ///   - planner: The pure plan, with its times.
    ///   - conditions: The memory pressure, Energy Saver and `browser.hibernation` until the first
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
    /// it after. A page that was hidden or frozen drops the picture of its hide; a discarded one keeps
    /// it to show while it draws again.
    package func show(_ key: String, page: any PageLifecycleTarget) {
        guard let object = page.object else { return remove(key) }
        let previous = entries[key]
        let same = previous?.target.object === object
        var entry = adopt(key, page: page, object: object)
        entry.state = .active
        entry.hiddenAt = nil
        entry.callThawEnds = nil
        entries[key] = entry
        hiddenKeys.remove(key)
        if mostRecentlyHidden == key { mostRecentlyHidden = nil }
        guard same, let state = previous?.state, state != .active else { return }
        if state != .discarded { page.dropHideSnapshot() }
        if state == .frozen || state == .discarded { page.thaw() }
    }

    /// `key` stopped showing `page`: the page keeps its last frame now, the one turn it is sure to be
    /// running and in its window. Arms the pass for when it stops being recently visible, and for the
    /// page that held `mostRecentlyUsed` until now, which may freeze from then on.
    package func hide(_ key: String, page: any PageLifecycleTarget) {
        guard let object = page.object else { return remove(key) }
        // A new view (made again after a discard) runs: it starts hidden, whatever the old one was.
        let replaced = entries[key]?.target.object !== object
        var entry = adopt(key, page: page, object: object)
        let now = uptime()
        let hides = entry.state == .active || replaced
        if hides {
            entry.state = .hidden
            entry.hiddenAt = now
        }
        entries[key] = entry
        hiddenKeys.insert(key)
        if hides { page.keepHideSnapshot() }
        guard entry.state != .discarded else { return }
        let window = Duration.seconds(planner.timing.visibleWindow(energySaver: conditions.energySaver))
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
    /// ``PageLoadState``; its document's keepAlive or a host hold, ``PageKeepReasons``): a hidden
    /// page is looked at again now, so a reason that ends while the page is hidden lets it freeze,
    /// and one that starts thaws it.
    package func pageReasonsDidChange(_ page: AnyObject) {
        guard let key = keys[ObjectIdentifier(page)], entries[key]?.target.object === page,
              hiddenKeys.contains(key) else { return }
        arm(at: uptime())
    }

    /// Whether `page` is held as shown, so its next ``hide(_:page:)`` pictures it first: a hide of its engine waits for that.
    package func picturesNextHide(of page: AnyObject) -> Bool {
        keys[ObjectIdentifier(page)].flatMap { entries[$0] }.map { $0.target.object === page && $0.state == .active } ?? false
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

    /// A call that needs `page` running reached it frozen (``PageFrozenPush/thawsFirst``): it thaws now
    /// and counts as hidden. For one recently visible window it keeps ``KeepReason/pageCall``, so a pass
    /// armed before does not freeze it under the call; the page reports a longer call that waits for its
    /// answer itself. The pass at the window's end freezes it again, as Chrome refreezes once no
    /// `CannotFreezeReason` holds (components/performance_manager/freezing/freezing_policy.cc). Its hidden
    /// time stays: a call neither makes it the most recently used page nor moves its discard.
    package func thawForCall(_ page: AnyObject) {
        guard let key = keys[ObjectIdentifier(page)], var entry = entries[key], entry.target.object === page,
              entry.state == .frozen else { return }
        let ends = uptime() + .seconds(planner.timing.visibleWindow(energySaver: conditions.energySaver))
        entry.state = .hidden
        entry.callThawEnds = ends
        entries[key] = entry
        entry.target.thaw()
        arm(at: ends)
    }

    /// The memory pressure, Energy Saver, or `browser.hibernation` and its companions changed (the
    /// app's browser hibernation passes on what it follows): a pass looks again. When pressure turns
    /// critical and ``leavesCriticalEventToUrgentPass`` is set, that pass discards nothing: the event's
    /// discard is the app's urgent pass (``urgentCandidates()``, ``urgentDiscard(_:)``).
    package func setConditions(_ conditions: PageLifecyclePlanner.Conditions) {
        guard conditions != self.conditions else { return }
        let turnsCritical = conditions.pressure == .critical && self.conditions.pressure != .critical
        self.conditions = conditions
        if turnsCritical, leavesCriticalEventToUrgentPass { holdDiscards() }
        if conditions.pressure != .critical { noDiscardBefore = nil }
        if !hiddenKeys.isEmpty { arm(at: uptime()) }
    }

    // MARK: Urgent pass (the app's critical memory event, O(hidden pages))

    /// Discards wait one urgent pace interval from now.
    private func holdDiscards() {
        noDiscardBefore = uptime() + .seconds(planner.timing.urgentPace.interval)
    }

    // MARK: Pass (at a deadline, O(hidden pages))

    /// Plans the hidden pages and performs the plan; arms the next deadline, if any. The deadline
    /// calls it.
    package func runPass() {
        nextPassAt = nil
        deadline.cancel()
        let now = uptime()
        let (pages, callThawEnds) = hiddenPages(at: now)
        let plan = planner.plan(pages, conditions: conditions)
        mostRecentlyHidden = nil
        if let hold = noDiscardBefore, now >= hold { noDiscardBefore = nil }
        var refused = false
        var held = false
        for decision in plan.decisions.values {
            if decision.keptBy.contains(.mostRecentlyUsed) { mostRecentlyHidden = decision.key }
            // The urgent pass took the critical event's discard: this one waits (freezes go on).
            if noDiscardBefore != nil, decision.state == .discarded, entries[decision.key]?.state != .discarded {
                held = true
                continue
            }
            if !perform(decision) { refused = true }
        }
        if let next = plan.nextCheck { arm(at: now + .seconds(next)) }
        if let callThawEnds { arm(at: callThawEnds) }
        if held, let hold = noDiscardBefore { arm(at: hold) }
        // A refused discard is due still: the next pass tries again at the discard pace, as Chrome's
        // discarder takes a tab it could not discard on its next pass.
        if refused { arm(at: now + .seconds(planner.timing.pace(at: conditions.pressure).interval)) }
        didRunPass?()
    }

    /// Moves one page toward the planned state. A pass only moves pages down (hidden, frozen,
    /// discarded); it thaws a frozen page only for a reason that appeared since
    /// (``PageLifecyclePlanner/KeepReason/thawsFrozenPage``: loading, focus, a setting), never for time
    /// alone: the most recently used one, or a longer recently visible window after Energy Saver ends.
    ///
    /// - Returns: False when the page refused its discard: it keeps the state it was in.
    private func perform(_ decision: PageLifecyclePlanner.Decision) -> Bool {
        guard var entry = entries[decision.key], entry.state != decision.state else { return true }
        switch (entry.state, decision.state) {
        case (.hidden, .frozen):
            guard entry.target.freeze() else {
                // Refused (its engine page is still starting, or still counts it visible): asked
                // again after one recently visible window, as BrowserHibernation asks a refused
                // page again after freezeSeconds. The plan's own deadline may be the discard, or none.
                let retry = planner.timing.visibleWindow(energySaver: conditions.energySaver)
                arm(at: uptime() + .seconds(retry))
                return true
            }
        case (.hidden, .discarded), (.frozen, .discarded):
            guard entry.target.discard() else { return false }
        case (.frozen, .hidden):
            guard decision.keptBy.contains(where: \.thawsFrozenPage) else { return true }
            entry.target.thaw()
        default:
            return true
        }
        entry.state = decision.state
        entries[decision.key] = entry
        return true
    }

    // MARK: Helpers

    private func uptime() -> Duration { deadlines.uptime }

    /// The hidden pages, discarded ones included, as the planner takes them at `now`, and the earliest
    /// end of a call's thaw still to come (``thawForCall(_:)``); pages whose view went away are forgotten.
    private func hiddenPages(at now: Duration) -> (pages: [PageLifecyclePlanner.Page], callThawEnds: Duration?) {
        var pages: [PageLifecyclePlanner.Page] = []
        pages.reserveCapacity(hiddenKeys.count)
        var gone: [String] = []
        var callThawEnds: Duration?
        for key in hiddenKeys {
            guard let entry = entries[key], entry.target.object != nil, let hiddenAt = entry.hiddenAt else {
                gone.append(key)
                continue
            }
            var reasons = entry.reasons.union(entry.target.lifecycleKeepReasons)
            if let ends = entry.callThawEnds {
                if ends > now {
                    reasons.insert(.pageCall)
                    callThawEnds = min(callThawEnds ?? ends, ends)
                } else {
                    entries[key]?.callThawEnds = nil
                }
            }
            pages.append(PageLifecyclePlanner.Page(
                key: key, group: entry.target.lifecycleGroup, hiddenFor: Self.seconds(now - hiddenAt),
                keepReasons: reasons, isDiscarded: entry.state == .discarded))
        }
        for key in gone { remove(key) }
        return (pages, callThawEnds)
    }

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

// The app's one urgent pass over tabs, chats and pages (``UrgentDiscardRanker/run(_:)``) ranks this
// lifecycle's hidden pages with the others, O(hidden pages).
extension PageLifecycle: UrgentDiscardOwner {
    /// The hidden pages the urgent pass may discard (``PageLifecyclePlanner/urgentCandidates(_:conditions:)``)
    /// whose discard frees an engine page (``PageLifecycleTarget/holdsEnginePage``).
    package func urgentCandidates() -> [UrgentDiscardRanker.Candidate] {
        planner.urgentCandidates(hiddenPages(at: uptime()).pages, conditions: conditions)
            .filter { entries[$0.key]?.target.holdsEnginePage == true }
    }

    /// The urgent pass chose hidden page `key`: it is discarded now, from the hide-time picture and
    /// state, with no call into the page and no lifecycle pass. False for a page that is shown, already
    /// discarded or unknown, or that refused.
    package func urgentDiscard(_ key: String) -> Bool {
        guard var entry = entries[key], hiddenKeys.contains(key), entry.target.object != nil,
              entry.state == .hidden || entry.state == .frozen, entry.target.discard() else { return false }
        entry.state = .discarded
        entries[key] = entry
        return true
    }

    /// The urgent pass ran: this lifecycle's own discards wait one urgent pace interval from now.
    package func urgentPassDidRun() {
        holdDiscards()
        if !hiddenKeys.isEmpty, let hold = noDiscardBefore { arm(at: hold) }
    }
}
