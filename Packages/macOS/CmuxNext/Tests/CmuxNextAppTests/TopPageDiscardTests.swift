import AppKit
@testable import CmuxNextApp
import CmuxNextHibernation
import CmuxNextPages
import Testing

/// Hidden top pages are discarded with a view-state record: a page hidden past its
/// policy releases its view and shows again with its scroll and selection; typed text keeps it; a page
/// with no owner (a web-backed page) never goes; at most the budget of hidden top pages stays live
/// across every window, least recently hidden first, never one the person just left.
@MainActor @Suite struct TopPageDiscardTests {
    private static let history = TopPageRoute.page(.history)
    private static let bookmarks = TopPageRoute.page(.bookmarks)
    private static let settings = TopPageRoute.page(.settings)

    @Test func aHiddenPageIsReleasedAfterItsTimeoutAndComesBackScrolledAndSelected() throws {
        let world = World()
        let host = world.host()
        let owner = FakeOwner()
        world.pages.owners[Self.history] = owner
        weak var released: FakePageView?
        try autoreleasepool {
            let page = try #require(host.view(for: Self.history, in: nil) as? FakePageView)
            released = page
            host.contentDidChange(shown: page)
            page.scrollList(to: 500)
            owner.selection = "conv_7"
            host.contentDidChange(shown: nil)
        }
        world.fire(host)
        #expect(world.deadline(host).delay == .seconds(600), "the deadline is the policy's timeout")

        world.clock.advance(.seconds(599))
        world.fire(host)
        #expect(host.views[Self.history] != nil, "a page hidden less than its timeout stays")

        world.clock.advance(.seconds(2))
        autoreleasepool { world.fire(host) }
        #expect(released == nil, "the hidden page's view is still alive past its timeout")
        #expect(host.views[Self.history] == nil)
        #expect(host.key(for: Self.history) == nil)
        #expect(world.pages.closed == ["key-page:history-1"], "the provider forgets the released view")
        #expect(host.releasedCount == 1)

        let again = try #require(host.view(for: Self.history, in: nil) as? FakePageView)
        host.contentDidChange(shown: again)
        host.didShow(Self.history)
        #expect(again.listOffset == 500, "the rebuilt page scrolls back to where it was")
        #expect(owner.restored == "conv_7", "the rebuilt page shows its selection again")
        #expect(host.released[Self.history] == nil)
    }

    @Test func typedTextOrAnUnsavedDraftKeepsThePage() throws {
        let world = World()
        let host = world.host()
        let owner = FakeOwner()
        world.pages.owners[Self.history] = owner
        let page = try #require(host.view(for: Self.history, in: nil) as? FakePageView)
        page.search.stringValue = "invoices"
        host.contentDidChange(shown: nil)
        world.clock.advance(.seconds(601))
        world.fire(host)
        #expect(host.views[Self.history] === page, "a search query no model keeps was dropped")
        #expect(world.deadline(host).delay == .seconds(600), "a kept page is looked at again a timeout later")

        page.search.stringValue = ""
        owner.unsaved = true
        world.clock.advance(.seconds(601))
        world.fire(host)
        #expect(host.views[Self.history] === page, "a page's unsaved draft was dropped")

        owner.unsaved = false
        world.clock.advance(.seconds(601))
        world.fire(host)
        #expect(host.views[Self.history] == nil, "with nothing typed the page goes")
    }

    @Test func aNeverPolicyKeepsThePageForTheWindowsLife() throws {
        let world = World()
        let host = world.host()
        let owner = FakeOwner()
        owner.policy = .never
        world.pages.owners[Self.history] = owner
        _ = try #require(host.view(for: Self.history, in: nil))
        host.contentDidChange(shown: nil)
        world.clock.advance(.seconds(3600))
        world.fire(host)
        #expect(host.views[Self.history] != nil)
        #expect(!world.deadline(host).armed, "a page that never goes needs no deadline")
        #expect(!host.release(Self.history, for: .proactive))
    }

    @Test func theShownPageIsNeverReleased() throws {
        let world = World()
        let host = world.host()
        world.pages.owners[Self.history] = FakeOwner()
        let page = try #require(host.view(for: Self.history, in: nil))
        host.contentDidChange(shown: page)
        world.clock.advance(.seconds(3600))
        world.fire(host)
        #expect(host.views[Self.history] === page)
        #expect(!host.release(Self.history, for: .proactive))
    }

    @Test func theHiddenBudgetAppliesAcrossWindowsLeastRecentlyHiddenFirst() throws {
        let world = World()
        world.ownEveryPage()
        let first = world.host(limit: 2)
        let second = world.host(limit: 2)
        _ = try #require(second.view(for: Self.settings, in: nil))
        second.contentDidChange(shown: nil)
        world.clock.advance(.seconds(40))
        _ = try #require(first.view(for: Self.history, in: nil))
        first.contentDidChange(shown: nil)
        world.clock.advance(.seconds(40))
        world.fire(second)
        world.fire(first)
        #expect(second.views[Self.settings] != nil && first.views[Self.history] != nil, "a budget of two released one of two hidden pages")

        // A third hidden page in the first window: the least recently hidden page, the second window's, goes.
        let kept = try #require(first.view(for: Self.bookmarks, in: nil) as? FakePageView)
        kept.search.stringValue = "news"
        first.contentDidChange(shown: nil)
        world.fire(first)
        #expect(second.views[Self.settings] == nil, "the other window's least recently hidden page stayed over the budget")
        #expect(first.views[Self.history] != nil)
        #expect(first.views[Self.bookmarks] === kept)

        // The kept page still counts, so the next hide in the second window lets the first window's next page go.
        world.clock.advance(.seconds(10))
        let home = try #require(second.view(for: .home, in: nil))
        second.contentDidChange(shown: nil)
        world.fire(second)
        #expect(first.views[Self.history] == nil, "the next least recently hidden page stayed over the budget")
        #expect(first.views[Self.bookmarks] === kept, "a page with typed text went for the budget")
        #expect(second.views[.home] === home)
    }

    @Test func theBudgetNeverTakesAPageThePersonJustLeft() throws {
        let world = World()
        world.ownEveryPage()
        let host = world.host(limit: 1)
        _ = try #require(host.view(for: Self.history, in: nil))
        host.contentDidChange(shown: nil)
        world.clock.advance(.seconds(5))
        _ = try #require(host.view(for: Self.bookmarks, in: nil))
        host.contentDidChange(shown: nil)
        world.fire(host)
        #expect(host.views[Self.history] != nil, "a page hidden 5 s went for the budget in the next turn")
        #expect(world.deadline(host).delay == TopPageHost.budgetMinimumHidden - .seconds(5),
                "the deadline is when the least recently hidden page is old enough")

        world.clock.advance(TopPageHost.budgetMinimumHidden - .seconds(5))
        world.fire(host)
        #expect(host.views[Self.history] == nil, "the least recently hidden page stayed over the budget")
        #expect(host.views[Self.bookmarks] != nil)
    }

    @Test func aPageWithNoOwnerIsNeverReleased() throws {
        let world = World()
        let host = world.host(limit: 0)
        let page = try #require(host.view(for: Self.settings, in: nil))
        host.contentDidChange(shown: nil)
        world.clock.advance(.seconds(3600))
        world.fire(host)
        #expect(host.views[Self.settings] === page, "a web-backed page, which records nothing, was released")
        #expect(!host.release(Self.settings, for: .proactive))
        #expect(!world.deadline(host).armed, "a page that never goes needs no deadline")
    }

    @Test func theDefaultsKeepTypedTextAndRestoreTheScroll() throws {
        let world = World()
        let host = world.host()
        world.pages.plain[Self.history] = PlainOwner()
        let page = try #require(host.view(for: Self.history, in: nil) as? FakePageView)
        page.scrollList(to: 300)
        page.search.stringValue = "receipts"
        host.contentDidChange(shown: nil)
        world.clock.advance(.seconds(601))
        world.fire(host)
        #expect(host.views[Self.history] === page, "the default dropped text typed in a field")

        page.search.stringValue = ""
        world.clock.advance(.seconds(601))
        world.fire(host)
        #expect(host.views[Self.history] == nil)
        let again = try #require(host.view(for: Self.history, in: nil) as? FakePageView)
        host.contentDidChange(shown: again)
        host.didShow(Self.history)
        #expect(again.listOffset == 300, "the default restore left the rebuilt page at the top")
    }

    @Test func aDuePageStillOnScreenGoesWhenItLeavesTheWindow() throws {
        let world = World()
        let host = world.host()
        _ = NSApplication.shared
        world.pages.owners[Self.history] = FakeOwner()
        let page = try #require(host.view(for: Self.history, in: nil))
        // A paint hold keeps the outgoing page in the window until the incoming one paints.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(page)
        host.contentDidChange(shown: nil)
        world.clock.advance(.seconds(601))
        world.fire(host)
        #expect(host.views[Self.history] === page, "a page still on screen was released")
        #expect(!world.deadline(host).armed, "a page on screen is polled instead of waiting for it to leave")

        page.removeFromSuperview()
        host.contentDidLeaveWindow()
        #expect(world.deadline(host).delay == .zero)
        world.fire(host)
        #expect(host.views[Self.history] == nil, "the page that left the window stayed past its timeout")
    }

    @Test func homeSelectionOutlivesTheReleasedHome() throws {
        let world = World()
        let host = world.host()
        let owner = FakeOwner()
        owner.selection = "conv_9"
        world.pages.owners[.home] = owner
        _ = try #require(host.view(for: .home, in: nil))
        host.contentDidChange(shown: nil)
        world.clock.advance(.seconds(601))
        world.fire(host)
        #expect(host.views[.home] == nil)
        #expect(host.homeSelection?.rawValue == "conv_9", "a home.* action without a conversation lost Home's")
    }

    @Test func offTheFeatureEveryPageStaysAsBefore() throws {
        let world = World()
        let host = world.host(discards: false)
        _ = try #require(host.view(for: Self.history, in: nil))
        _ = try #require(host.view(for: Self.bookmarks, in: nil))
        _ = try #require(host.view(for: Self.settings, in: nil))
        host.contentDidChange(shown: nil)
        world.clock.advance(.seconds(3600))
        #expect(!world.deadline(host).armed)
        #expect(!host.release(Self.history, for: .proactive))
        host.plan()
        #expect(host.views.count == 3)
    }

    @Test func teardownForgetsEveryPage() throws {
        let world = World()
        let host = world.host()
        _ = try #require(host.view(for: Self.history, in: nil))
        _ = try #require(host.view(for: .home, in: nil))
        host.contentDidChange(shown: nil)
        host.teardown()
        #expect(host.views.isEmpty)
        #expect(world.pages.closed == ["key-page:history-1"], "Home has no provider key to close")
        #expect(!world.deadline(host).armed)
    }
}

@MainActor
private final class World {
    let pages = FakeTopPages()
    let clock = FakeClock()
    private var hosts: [TopPageHost] = []
    private var deadlines: [ObjectIdentifier: FakeDeadline] = [:]

    func host(discards: Bool = true, limit: Int = 8) -> TopPageHost {
        let deadline = FakeDeadline()
        let pages = self.pages
        let host = TopPageHost(make: { route, _ in pages.makePage(route) }, closed: { _, key in pages.closed.append(key) },
                               discardable: { route, _ in pages.owner(route) }, title: { $0.rawValue },
                               discards: discards, hiddenLimit: limit, hosts: { [unowned self] in self.hosts }, deadline: deadline)
        host.now = { [clock] in clock.now }
        hosts.append(host)
        deadlines[ObjectIdentifier(host)] = deadline
        return host
    }

    func deadline(_ host: TopPageHost) -> FakeDeadline { deadlines[ObjectIdentifier(host)]! }

    /// Every route has an owner, so each page may go.
    func ownEveryPage() {
        for route in [TopPageRoute.home, .page(.history), .page(.bookmarks), .page(.settings)] { pages.owners[route] = FakeOwner() }
    }

    /// Runs `host`'s pending deadline, as its timer would.
    func fire(_ host: TopPageHost) { deadline(host).fire() }
}

private final class FakeClock {
    private(set) var now = ContinuousClock.now
    func advance(_ duration: Duration) { now = now.advanced(by: duration) }
}

@MainActor
private final class FakeDeadline: PageDiscardDeadline {
    private(set) var delay: Duration?
    private var action: (@MainActor () -> Void)?
    var armed: Bool { action != nil }

    func arm(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.action = action
    }

    func disarm() {
        delay = nil
        action = nil
    }

    func fire() {
        guard let action else { return }
        self.action = nil
        delay = nil
        action()
    }
}

@MainActor
private final class FakeTopPages {
    var owners: [TopPageRoute: FakeOwner] = [:]
    var plain: [TopPageRoute: PlainOwner] = [:]
    var closed: [String] = []
    private var made: [TopPageRoute: Int] = [:]

    func owner(_ route: TopPageRoute) -> (any PageDiscardable)? {
        if let owner = owners[route] { return owner }
        return plain[route]
    }

    func makePage(_ route: TopPageRoute) -> (view: NSView, key: String?)? {
        made[route, default: 0] += 1
        let key: String? = route == .home ? nil : "key-\(route.rawValue)-\(made[route, default: 0])"
        return (FakePageView(frame: NSRect(x: 0, y: 0, width: 200, height: 120)), key)
    }
}

@MainActor
private final class FakeOwner: PageDiscardable {
    var policy = PageDiscardPolicy.standard
    var unsaved = false
    var selection: String?
    private(set) var restored: String?

    var pageDiscardPolicy: PageDiscardPolicy { policy }
    func holdsUnsavedInput(_ view: NSView) -> Bool { unsaved || PageViewState.holdsTypedText(view) }
    func saveViewState(_ view: NSView, into state: inout PageViewState) { state.selection = selection }
    func restoreViewState(_ state: PageViewState, in view: NSView) {
        restored = state.selection
        view.layoutSubtreeIfNeeded()
        state.restoreScroll(in: view)
    }
}

/// An owner that takes every default.
@MainActor
private final class PlainOwner: PageDiscardable {}

/// A page with a long scrolled list and a search field, as Home's list.
private final class FakePageView: NSView {
    let list = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    let search = NSTextField(frame: NSRect(x: 0, y: 100, width: 200, height: 20))

    override init(frame: NSRect) {
        super.init(frame: frame)
        list.documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 2000))
        addSubview(list)
        search.isEditable = true
        addSubview(search)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func scrollList(to y: CGFloat) { list.documentView?.scroll(NSPoint(x: 0, y: y)) }
    var listOffset: CGFloat { list.contentView.bounds.origin.y }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
