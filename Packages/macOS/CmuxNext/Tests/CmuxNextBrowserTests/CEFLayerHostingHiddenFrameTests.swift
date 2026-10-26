import AppKit
import CmuxNextCompat
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Testing

/// A hosted page in the app-wide hidden frame list (p03-rendering-099, `memoryHiddenFrameLRU`): locked
/// while the shown tab's visibility node is visible, unlocked while hidden, hosting off when the list
/// evicts it, hosted again when the node shows. Fake fork, fake list, the run-loop turn ended by the test.
@MainActor
@Suite struct CEFLayerHostingHiddenFrameTests {
    let fake = CEFLayerHostingTests.FakeFork()
    let turn = CEFLayerHostingTests.Turn()
    private let keeper = FakeKeeper()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let window = VisibilityNode(root: "window", own: .visible)

    private func makeHosting() -> CEFLayerHosting {
        let turn = turn
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) })
        hosting.view = view
        return hosting
    }

    private func makeHostedPage(node: VisibilityNode) -> CEFLayerHosting {
        let hosting = makeHosting()
        hosting.pageWindowCreated(browser: 3, fork: fake.fork, frames: keeper, node: node)
        turn.end()
        return hosting
    }

    @Test func aShownPageIsLockedAndAHiddenOneUnlocked() {
        let tab = VisibilityNode("tab", own: .visible, parent: window)
        let hosting = makeHostedPage(node: tab)
        #expect(keeper.locked == [hosting.frameID], "a shown page joined the list unlocked")

        // The workspace hid: the window's node flips, the tab's follows.
        window.set(.hidden)
        #expect(keeper.unlocked == [hosting.frameID], "a hidden page stayed locked")

        window.set(.visible)
        #expect(keeper.locked == [hosting.frameID])
        #expect(keeper.unlocked.isEmpty)
    }

    @Test func aPageCreatedHiddenJoinsUnlocked() {
        let tab = VisibilityNode("tab", own: .hidden, parent: window)
        let hosting = makeHostedPage(node: tab)
        #expect(keeper.unlocked == [hosting.frameID])
    }

    @Test func anEvictedHiddenPageTurnsHostingOffAndIsHostedAgainWhenShown() throws {
        let tab = VisibilityNode("tab", own: .visible, parent: window)
        let hosting = makeHostedPage(node: tab)
        tab.set(.hidden)

        keeper.evict(hosting.frameID)
        #expect(hosting.page == nil, "the evicted page's hosted view stayed")
        #expect(hosting.isEvicted)
        #expect(hosting.evictions == 1)
        #expect(fake.calls.last?.browser == 3)
        #expect(fake.calls.last?.enabled == false, "hosting stayed on for an evicted page")
        #expect(view.subviews.isEmpty)

        tab.set(.visible)
        #expect(!hosting.isEvicted)
        turn.end()
        let page = try #require(hosting.page, "the page was not hosted again when its tab showed")
        #expect(page.contextID == 7)
        #expect(fake.calls.last?.enabled == true)
        #expect(keeper.locked == [hosting.frameID])
    }

    @Test func aTabSwitchFollowsTheShownTabsNode() {
        let first = VisibilityNode("tab:1", own: .visible, parent: window)
        let second = VisibilityNode("tab:2", own: .hidden, parent: window)
        let hosting = makeHostedPage(node: first)

        first.set(.hidden)
        second.set(.visible)
        hosting.pageShown(browser: 4, node: second)
        #expect(keeper.locked == [hosting.frameID], "the page did not follow the shown tab")
        #expect(fake.calls.count == 1, "a tab switch in a hosted pane called the fork")

        first.set(.visible)
        first.set(.hidden)
        #expect(keeper.locked == [hosting.frameID], "the old tab's node still moves the lock")
    }

    @Test func aStoppedPageLeavesTheList() {
        let tab = VisibilityNode("tab", own: .visible, parent: window)
        let hosting = makeHostedPage(node: tab)
        hosting.stop()
        #expect(keeper.locked.isEmpty && keeper.unlocked.isEmpty)
        #expect(keeper.removed == [hosting.frameID])
    }

    @Test func withoutANodeThePageStaysLocked() {
        let hosting = makeHosting()
        hosting.pageWindowCreated(browser: 3, fork: fake.fork, frames: keeper)
        turn.end()
        #expect(keeper.locked == [hosting.frameID])
        #expect(keeper.unlocked.isEmpty)
    }

    @Test func withoutAListAHiddenPageKeepsItsHostedView() {
        let tab = VisibilityNode("tab", own: .visible, parent: window)
        let hosting = makeHosting()
        hosting.pageWindowCreated(browser: 3, fork: fake.fork, node: tab)
        turn.end()
        tab.set(.hidden)
        #expect(hosting.page != nil)
        #expect(fake.calls.count == 1)
    }
}

/// A list that records what the hosting tells it and evicts when the test says.
@MainActor
private final class FakeKeeper: HiddenFrameKeeper {
    private(set) var unlocked: [HiddenFrameID] = []
    private(set) var locked: [HiddenFrameID] = []
    private(set) var removed: [HiddenFrameID] = []
    private var evictions: [HiddenFrameID: @MainActor () -> Void] = [:]

    func add(_ id: HiddenFrameID, locked isLocked: Bool, evict: @escaping @MainActor () -> Void) {
        forget(id)
        evictions[id] = evict
        if isLocked { locked.append(id) } else { unlocked.append(id) }
    }

    func remove(_ id: HiddenFrameID) {
        removed.append(id)
        forget(id)
    }

    func lock(_ id: HiddenFrameID) {
        unlocked.removeAll { $0 == id }
        if !locked.contains(id) { locked.append(id) }
    }

    func unlock(_ id: HiddenFrameID) {
        locked.removeAll { $0 == id }
        unlocked.append(id)
    }

    func evict(_ id: HiddenFrameID) {
        guard let evict = evictions[id] else { return }
        forget(id)
        evict()
    }

    private func forget(_ id: HiddenFrameID) {
        unlocked.removeAll { $0 == id }
        locked.removeAll { $0 == id }
        evictions[id] = nil
    }
}
