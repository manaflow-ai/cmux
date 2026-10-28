import CmuxNextWakeups
import Testing

/// The visibility tree (VisibilityNode.swift): effective = min(own, parent),
/// a flip visits only the children it can change, subscribers hear only flips, and the tree keeps
/// nothing alive.
@MainActor @Suite(.timeLimit(.minutes(1))) struct VisibilityTreeTests {
    /// The R1 case: hidden rows under a window that flips cost no visit and no notification.
    @Test func ownHiddenChildrenUnderAFlippingParentCostNothing() {
        let window = VisibilityNode(root: "window", own: .visible)
        var notifications = 0
        var tokens: [VisibilitySubscription] = []
        let rows = (0..<1000).map { index in
            let row = VisibilityNode("row:\(index)", own: .hidden, parent: window)
            tokens.append(row.subscribe(owner: "row") { _ in notifications += 1 })
            return row
        }
        for _ in 0..<10 {
            window.set(.hidden)
            window.set(.occluded)
            window.set(.visible)
        }
        #expect(rows.reduce(0) { $0 + $1.visits } == 0)
        #expect(notifications == 0)
        #expect(rows.allSatisfy { $0.effective == .hidden })
        #expect(window.childCounts.hidden == 1000 && window.childCounts.shown == 0)
        _ = tokens
    }

    @Test func aParentGoingVisibleNotifiesOnlyOwnVisibleChildren() {
        let window = VisibilityNode(root: "window", own: .hidden)
        var heard: [String: [Visibility]] = [:]
        var tokens: [VisibilitySubscription] = []
        let children = (0..<10).map { index in
            let child = VisibilityNode("tab:\(index)", own: index.isMultiple(of: 2) ? .visible : .hidden, parent: window)
            tokens.append(child.subscribe(owner: "tab") { heard[child.name, default: []].append($0) })
            return child
        }
        window.set(.visible)
        let visibleNames = Set(children.filter { $0.own == .visible }.map(\.name))
        #expect(Set(heard.keys) == visibleNames)
        #expect(heard.values.allSatisfy { $0 == [.visible] })
        #expect(children.filter { $0.own == .hidden }.allSatisfy { $0.visits == 0 })
        _ = tokens
    }

    @Test func effectiveIsTheMinimumOfOwnAndParent() {
        let app = VisibilityNode(root: "app", own: .visible)
        let window = VisibilityNode("window", parent: app)
        let workspace = VisibilityNode("workspace", own: .occluded, parent: window)
        let tab = VisibilityNode("tab", parent: workspace)
        #expect(tab.effective == .occluded)
        workspace.set(.visible)
        #expect(tab.isVisible)
        app.set(.hidden)
        #expect([window, workspace, tab].allSatisfy { $0.effective == .hidden })
        app.set(.visible)
        window.set(.occluded)
        #expect(tab.effective == .occluded && !tab.isVisible)
        tab.set(.hidden)
        window.set(.visible)
        #expect(tab.effective == .hidden && workspace.isVisible)
    }

    /// Setting the current state tells nobody; a node whose own state keeps it hidden hears
    /// nothing when its parent shows.
    @Test func subscribersHearOnlyFlips() {
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", parent: window)
        var heard: [Visibility] = []
        let token = tab.subscribe(owner: "tab") { heard.append($0) }
        tab.set(.visible)
        window.set(.visible)
        #expect(heard.isEmpty, "no flip, no call")
        window.set(.hidden)
        tab.set(.hidden)
        #expect(heard == [.hidden], "own hidden under a hidden parent is no flip")
        window.set(.visible)
        #expect(heard == [.hidden], "the tab's own hidden state keeps it hidden")
        _ = token
    }

    /// A subscriber that flips the tree back: every subscriber ends on the newest state, and the
    /// older pass stops telling the stale one.
    @Test func aSubscriberThatFlipsBackLeavesEveryoneOnTheNewestState() {
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", parent: window)
        var first: [Visibility] = []
        var second: [Visibility] = []
        let bounce = tab.subscribe(owner: "bounce") { value in
            first.append(value)
            if value == .hidden { window.set(.visible) }
        }
        let watcher = tab.subscribe(owner: "watcher") { second.append($0) }
        window.set(.hidden)
        #expect(first == [.hidden, .visible])
        #expect(second == [.visible])
        #expect(tab.isVisible)
        _ = (bounce, watcher)
    }

    @Test func releasingATokenEndsTheSubscriptionAndReleasesItsClosure() {
        let window = VisibilityNode(root: "window", own: .visible)
        weak var weakProbe: Probe?
        var calls = 0
        var token: VisibilitySubscription?
        do {
            let probe = Probe()
            weakProbe = probe
            token = window.subscribe(owner: "probe") { [probe] _ in
                _ = probe
                calls += 1
            }
        }
        weak var weakToken = token
        window.set(.hidden)
        #expect(calls == 1)
        token = nil
        #expect(weakToken == nil)
        #expect(weakProbe == nil, "the node does not keep the closure alive")
        window.set(.visible)
        #expect(calls == 1)
    }

    @Test func cancelEndsTheSubscriptionAtOnce() {
        let window = VisibilityNode(root: "window", own: .visible)
        var calls = 0
        let token = window.subscribe(owner: "cancel") { _ in calls += 1 }
        token.cancel()
        window.set(.hidden)
        #expect(calls == 0)
    }

    /// No strong cycle: nodes, tokens and deferred work are released with their owners.
    @Test func theTreeKeepsNothingAlive() {
        let window = VisibilityNode(root: "window", own: .visible)
        weak var weakWorkspace: VisibilityNode?
        weak var weakTab: VisibilityNode?
        weak var weakToken: VisibilitySubscription?
        weak var weakProbe: Probe?
        do {
            let workspace = VisibilityNode("workspace", own: .hidden, parent: window)
            let tab = VisibilityNode("tab", parent: workspace)
            let token = tab.subscribe(owner: "tab") { [weak tab] _ in _ = tab }
            let probe = Probe()
            tab.deferUntilVisible(key: "appearance") { [probe] in _ = probe }
            weakWorkspace = workspace
            weakTab = tab
            weakToken = token
            weakProbe = probe
            #expect(window.childCounts.hidden == 1)
        }
        #expect(weakWorkspace == nil && weakTab == nil && weakToken == nil && weakProbe == nil)
        #expect(window.childCounts.hidden == 0 && window.childCounts.shown == 0)
    }

    @Test func detachingAParentHidesItsSubtree() {
        let window = VisibilityNode(root: "window", own: .visible)
        let workspace = VisibilityNode("workspace", parent: window)
        let tab = VisibilityNode("tab", parent: workspace)
        var heard: [Visibility] = []
        let token = tab.subscribe(owner: "tab") { heard.append($0) }
        workspace.detach()
        #expect(workspace.parent == nil && workspace.effective == .hidden)
        #expect(tab.effective == .hidden && heard == [.hidden])
        window.set(.hidden)
        window.set(.visible)
        #expect(heard == [.hidden], "a detached subtree no longer follows the window")
        _ = token
    }

    /// Released children leave weak entries behind; inserts drop them, so a long-lived parent
    /// with churning rows keeps at most twice its live children (never one entry per row ever made).
    @Test func releasedChildrenAreDroppedFromTheParent() {
        let window = VisibilityNode(root: "window", own: .visible)
        for round in 0..<10 {
            let rows = (0..<1000).map { VisibilityNode("row:\(round):\($0)", own: $0.isMultiple(of: 2) ? .hidden : .visible, parent: window) }
            #expect(window.childCounts.shown == 500 && window.childCounts.hidden == 500)
            #expect(window.childEntryCount <= 2048, "round \(round) kept \(window.childEntryCount) entries")
            _ = rows
        }
        #expect(window.childCounts.shown == 0 && window.childCounts.hidden == 0)
        #expect(window.childEntryCount <= 2048)
    }

    /// A subscriber that hides and shows the node again inside its call: the remaining
    /// subscribers hear only the newest state, not the stale one after it.
    @Test func aNestedFlipAndUndoStopsTheStaleDelivery() {
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", parent: window)
        var first: [Visibility] = []
        var second: [Visibility] = []
        var bounced = false
        let bounce = tab.subscribe(owner: "bounce") { value in
            first.append(value)
            guard value == .hidden, !bounced else { return }
            bounced = true
            window.set(.visible)
            window.set(.hidden)
        }
        let watcher = tab.subscribe(owner: "watcher") { second.append($0) }
        window.set(.hidden)
        #expect(first == [.hidden, .visible, .hidden])
        #expect(second == [.visible, .hidden], "no second stale .hidden from the outer delivery")
        _ = (bounce, watcher)
    }

    @Test func attachAndDetachMoveTheSubtree() throws {
        let shown = VisibilityNode(root: "shown", own: .visible)
        let hidden = VisibilityNode(root: "hidden", own: .hidden)
        let pane = VisibilityNode("pane", parent: hidden)
        let tab = VisibilityNode("tab", parent: pane)
        var heard: [Visibility] = []
        let token = tab.subscribe(owner: "tab") { heard.append($0) }
        try pane.attach(to: shown)
        #expect(tab.isVisible && heard == [.visible])
        #expect(hidden.childCounts.shown == 0 && shown.childCounts.shown == 1)
        pane.detach()
        #expect(tab.effective == .hidden && heard == [.visible, .hidden])
        #expect(shown.childCounts.shown == 0)
        _ = token
    }

    @Test func attachRefusesARootAndACycle() throws {
        let window = VisibilityNode(root: "window", own: .visible)
        let pane = VisibilityNode("pane", parent: window)
        let tab = VisibilityNode("tab", parent: pane)
        #expect(throws: VisibilityNode.MoveError.isRoot) { try window.attach(to: tab) }
        #expect(throws: VisibilityNode.MoveError.wouldCycle) { try pane.attach(to: tab) }
        #expect(throws: VisibilityNode.MoveError.wouldCycle) { try pane.attach(to: pane) }
        #expect(tab.parent === pane && pane.parent === window && tab.isVisible)
    }

    @Test func ownStateChangesMoveAChildBetweenTheSets() {
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .hidden, parent: window)
        #expect(window.childCounts.hidden == 1 && window.childCounts.shown == 0)
        tab.set(.occluded)
        #expect(window.childCounts.hidden == 0 && window.childCounts.shown == 1)
        tab.set(.visible)
        #expect(window.childCounts.hidden == 0 && window.childCounts.shown == 1)
        tab.set(.hidden)
        #expect(window.childCounts.hidden == 1 && window.childCounts.shown == 0)
    }

    /// Recipe R-appear: three theme flips at 50 workspaces run the
    /// appearance body of the visible workspace only, then one body per workspace as each shows.
    @Test func aThemeFlipAtFiftyWorkspacesAppliesOnlyWhatIsOnScreenThenOncePerShow() {
        let counts = VisibilityWorkCounts()
        let window = VisibilityNode(root: "window", own: .visible, workCounts: counts)
        let workspaces = (0..<50).map { VisibilityNode("workspace:\($0)", own: $0 == 0 ? .visible : .hidden, parent: window) }
        var applied: [Int] = []
        for _ in 0..<3 {
            for (index, workspace) in workspaces.enumerated() {
                workspace.deferAppearance(owner: "TabStripView") { applied.append(index) }
            }
        }
        #expect(applied == [0, 0, 0], "a hidden workspace ran its appearance body")
        #expect(counts.appearanceApplies == 3)
        #expect(workspaces.dropFirst().allSatisfy { $0.deferredCount == 1 }, "a hidden workspace kept more than one body")

        workspaces[0].set(.hidden)
        for workspace in workspaces.dropFirst() {
            workspace.set(.visible)
            workspace.set(.hidden)
            workspace.set(.visible)
        }
        #expect(applied == [0, 0, 0] + Array(1..<50), "a shown workspace did not apply once")
        #expect(counts.appearanceApplies == 52)
    }

    /// A node counts into the counts of the root it is under when the body runs: a tab made under the
    /// unselected-tabs root and moved to a shown pane counts in the pane's tree; a detached node counts nowhere.
    @Test func appearanceAppliesCountInTheTreeTheNodeIsInWhenTheyRun() throws {
        let counts = VisibilityWorkCounts()
        let pane = VisibilityNode(root: "pane", own: .visible, workCounts: counts)
        let unselected = VisibilityNode(root: "tabs.unselected", own: .hidden)
        let tab = VisibilityNode("tab", parent: unselected)
        tab.deferAppearance(owner: "chrome") {}
        #expect(counts.appearanceApplies == 0)
        try tab.attach(to: pane)
        #expect(counts.appearanceApplies == 1, "the moved tab's body did not count in its new tree")
        tab.detach()
        #expect(tab.workCounts == nil)
        counts.reset()
        #expect(counts.appearanceApplies == 0)
    }

    /// One pending appearance body per owner on a node: two views on one node each re-theme on show.
    @Test func appearanceBodiesAreKeptPerOwner() {
        let tab = VisibilityNode(root: "tab", own: .hidden)
        var runs: [String] = []
        tab.deferAppearance(owner: "strip") { runs.append("strip:1") }
        tab.deferAppearance(owner: "bar") { runs.append("bar") }
        tab.deferAppearance(owner: "strip") { runs.append("strip:2") }
        tab.deferUntilVisible(key: "strip") { runs.append("strip-key") }
        #expect(tab.deferredCount == 3, "an owner's appearance body shares a key with plain deferred work")
        tab.set(.visible)
        #expect(runs == ["strip:2", "bar", "strip-key"])
    }

    @Test func deferredWorkRunsOncePerKeyOnShow() {
        let window = VisibilityNode(root: "window", own: .hidden)
        let tab = VisibilityNode("tab", parent: window)
        var runs: [String] = []
        for index in 0..<50 {
            tab.deferUntilVisible(key: "appearance") { runs.append("appearance:\(index)") }
        }
        tab.deferUntilVisible(key: "layout") { runs.append("layout") }
        tab.deferUntilVisible(key: "dropped") { runs.append("dropped") }
        tab.cancelDeferred(key: "dropped")
        #expect(runs.isEmpty && tab.deferredCount == 2)
        window.set(.occluded)
        #expect(runs.isEmpty, "occluded is not visible")
        window.set(.visible)
        #expect(runs == ["appearance:49", "layout"])
        #expect(tab.deferredCount == 0)
        tab.deferUntilVisible(key: "appearance") { runs.append("now") }
        #expect(runs.last == "now", "a visible node runs the work at once")
        window.set(.hidden)
        window.set(.visible)
        #expect(runs.count == 3)
    }

    /// Layout work waits only while the node is hidden (``VisibilityNode/deferUntilShown(key:_:)``): an occluded
    /// node keeps its layout ready, so it runs there, while the visible-only work still waits for visible.
    @Test func shownWorkRunsWhenOccludedAndVisibleWorkWaits() {
        let window = VisibilityNode(root: "window", own: .hidden)
        let tab = VisibilityNode("tab", parent: window)
        var runs: [String] = []
        tab.deferUntilVisible(key: "appearance") { runs.append("appearance") }
        tab.deferUntilShown(key: "size") { runs.append("size:1") }
        tab.deferUntilShown(key: "size") { runs.append("size:2") }
        #expect(runs.isEmpty && tab.deferredCount == 2)
        window.set(.occluded)
        #expect(runs == ["size:2"], "an occluded node did not apply its layout, or ran visible-only work")
        #expect(tab.deferredCount == 1)
        tab.deferUntilShown(key: "size") { runs.append("now") }
        #expect(runs.last == "now", "an occluded node held layout work")
        window.set(.visible)
        #expect(runs == ["size:2", "now", "appearance"])
        #expect(tab.deferredCount == 0)
    }

    /// A flip subscriber defers work on hide and shows the node again inside its call: the nested
    /// pass does not change what the rendering subscribers were told, and the work still runs.
    @Test func workDeferredAndShownInsideAFlipRunsOnce() {
        let window = VisibilityNode(root: "window", own: .visible)
        var runs = 0
        var bounced = false
        let bounce = window.subscribe(owner: "bounce") { value in
            guard value == .hidden, !bounced else { return }
            bounced = true
            window.deferUntilVisible(key: "k") { runs += 1 }
            window.set(.visible)
        }
        window.set(.hidden)
        #expect(window.isVisible)
        #expect(window.deferredCount == 0)
        #expect(runs == 1)
        window.set(.hidden)
        window.set(.visible)
        #expect(runs == 1, "no stale entry runs again on the next show")
        _ = bounce
    }

    @Test func hiddenSinceAndRecentMediaFollowTheInjectedClock() {
        let clock = FakeUptime()
        let window = VisibilityNode(root: "window", own: .visible, uptime: clock.read)
        let tab = VisibilityNode("tab", parent: window)
        #expect(tab.hiddenSince == nil)
        clock.now = .seconds(10)
        window.set(.occluded)
        #expect(tab.hiddenSince == .seconds(10))
        clock.now = .seconds(20)
        window.set(.hidden)
        #expect(tab.hiddenSince == .seconds(10), "occluded to hidden keeps the first time it stopped showing")
        window.set(.visible)
        #expect(tab.hiddenSince == nil)

        #expect(!tab.mediaActiveWithin(.seconds(30)))
        tab.setMediaActive(true)
        clock.now = .seconds(500)
        #expect(tab.mediaActiveWithin(.seconds(30)))
        tab.setMediaActive(false)
        clock.now = .seconds(529)
        #expect(tab.mediaActiveWithin(.seconds(30)))
        clock.now = .seconds(530)
        #expect(!tab.mediaActiveWithin(.seconds(30)))
    }
}

private final class Probe {}

@MainActor private final class FakeUptime {
    var now: Duration = .zero
    var read: VisibilityNode.Uptime { { self.now } }
}
