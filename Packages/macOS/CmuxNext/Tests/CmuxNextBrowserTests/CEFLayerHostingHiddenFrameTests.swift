import AppKit
import CmuxNextCompat
@testable import CmuxNextBrowser
import Testing

/// A hosted page in the app-wide hidden frame list (p03-rendering-099, `memoryHiddenFrameLRU`): locked
/// while its view shows, unlocked while hidden, hosting off when the list evicts it, hosted again when
/// the view shows. Fake fork, fake list, the run-loop turn ended by the test, the view in a real window.
@MainActor
@Suite struct CEFLayerHostingHiddenFrameTests {
    let fake = CEFLayerHostingTests.FakeFork()
    let turn = CEFLayerHostingTests.Turn()
    private let keeper = FakeKeeper()
    let window: NSWindow
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView?.addSubview(view)
    }

    private func makeHostedPage() -> CEFLayerHosting {
        let turn = turn
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) })
        hosting.view = view
        hosting.pageWindowCreated(browser: 3, fork: fake.fork, frames: keeper)
        turn.end()
        return hosting
    }

    @Test func aShownPageIsLockedAndAHiddenOneUnlocked() {
        let hosting = makeHostedPage()
        #expect(keeper.locked == [hosting.frameID], "a shown page joined the list unlocked")

        view.isHidden = true
        hosting.visibilityDidChange()
        #expect(keeper.unlocked == [hosting.frameID], "a hidden page stayed locked")

        view.isHidden = false
        hosting.visibilityDidChange()
        #expect(keeper.locked == [hosting.frameID])
        #expect(keeper.unlocked.isEmpty)
    }

    @Test func anEvictedHiddenPageTurnsHostingOffAndIsHostedAgainWhenShown() throws {
        let hosting = makeHostedPage()
        view.isHidden = true
        hosting.visibilityDidChange()

        keeper.evict(hosting.frameID)
        #expect(hosting.page == nil, "the evicted page's hosted view stayed")
        #expect(hosting.isEvicted)
        #expect(hosting.evictions == 1)
        #expect(fake.calls.last?.browser == 3)
        #expect(fake.calls.last?.enabled == false, "hosting stayed on for an evicted page")
        #expect(view.subviews.isEmpty)

        view.isHidden = false
        hosting.visibilityDidChange()
        #expect(!hosting.isEvicted)
        turn.end()
        let page = try #require(hosting.page, "the page was not hosted again when its view showed")
        #expect(page.contextID == 7)
        #expect(fake.calls.last?.enabled == true)
        #expect(keeper.locked == [hosting.frameID])
    }

    @Test func aStoppedPageLeavesTheList() {
        let hosting = makeHostedPage()
        hosting.stop()
        #expect(keeper.locked.isEmpty && keeper.unlocked.isEmpty)
        #expect(keeper.removed == [hosting.frameID])
    }

    @Test func withoutAListAHiddenPageKeepsItsHostedView() {
        let turn = turn
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) })
        hosting.view = view
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        view.isHidden = true
        hosting.visibilityDidChange()
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
