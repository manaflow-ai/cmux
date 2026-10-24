import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
@testable import MessagesLabHome
import Testing

/// A transcript counted as seen (`isVisibleToUser`, which reports reads) whenever its window was
/// key and on screen: a chat tab that is not selected, a parked workspace's chat and a pane scrolled
/// out of the strip all reported reads nobody saw, and every one of them answered each key and
/// occlusion notice of its window. Seen now means shown (no hidden flag of its own or an
/// ancestor's), inside a pane tab a pane the layout reports on screen presents (the ``PanePresence``
/// of its nearest ``PanePresenceHost`` ancestor; none: not seen), in a window a person can see; a
/// hidden transcript hears no window notice.
///
/// Geometry cannot say "on screen": a view's `visibleRect` is what its ancestors show in its own
/// coordinates, never empty for a pane moved out of the strip (no ancestor clips by default since
/// the macOS 14 SDK), and blind to the strip's layer masks (a pane under a docked column, clipped by
/// its nested area window) and to a pane faded to alpha 0. The layout's pane presence knows all of
/// them, and reaches the content cache's rendering set.
///
/// Every check reads a plain value (a `Bool` from a closure, an optional local): a failing check describes
/// the values its expression captured, and describing a view walks its AppKit objects, which crashed
/// the runner (a CI Mac's compose field held a null pasteboard) instead of reporting the failure.
@MainActor @Suite(.serialized) struct HomeTranscriptVisibilityTests {
    private struct Fixture {
        let window: NSWindow
        let pane: PresenceHost
        let view: HomeNativeTranscriptView
    }

    /// The view that stands for a tab, as a page tab's or conversation tab's view does.
    private final class PresenceHost: NSView, PanePresenceHost {
        let presence = PanePresence(isPresented: true)
        var panePresence: PanePresence? { presence }
    }

    /// A transcript in a presented pane tab (`pane`) of a window a person sees.
    private static func fixture() -> Fixture {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        let home = HomeStore(source: MockHomeSource(options: .immediate))
        let view = HomeNativeTranscriptView(store: home, conversation: ConversationID("conv_seen"), me: ParticipantID("user_me"))
        view.isWindowSeen = { _ in true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        window.contentView = container
        let pane = PresenceHost(frame: container.bounds)
        container.addSubview(pane)
        let column = NSView(frame: pane.bounds) // a container between the tab and the transcript
        pane.addSubview(column)
        view.frame = column.bounds
        column.addSubview(view)
        return Fixture(window: window, pane: pane, view: view)
    }

    @Test func aTranscriptUnderAHiddenAncestorIsNotSeen() {
        let fixture = Self.fixture()
        defer { fixture.window.close() }
        let seen = { fixture.view.transcript.isVisibleToUser }
        let observing = { fixture.view.isObservingWindow }
        #expect(seen())
        fixture.pane.isHidden = true // a tab not selected, a parked workspace
        #expect(!seen(), "a hidden transcript reports reads")
        #expect(!observing(), "a hidden transcript hears its window's notices")
        fixture.pane.isHidden = false
        #expect(seen())
        #expect(observing())
    }

    @Test func aTranscriptMovedIntoAWindowUnderAHiddenAncestorIsNotSeen() {
        let fixture = Self.fixture()
        defer { fixture.window.close() }
        let seen = { fixture.view.transcript.isVisibleToUser }
        let observing = { fixture.view.isObservingWindow }
        fixture.view.removeFromSuperview()
        fixture.pane.isHidden = true
        fixture.pane.addSubview(fixture.view)
        #expect(!seen())
        #expect(!observing())
    }

    @Test func aTranscriptItsHostDoesNotPresentIsNotSeenAndHearsNoWindowNotice() {
        let fixture = Self.fixture()
        defer { fixture.window.close() }
        let seen = { fixture.view.transcript.isVisibleToUser }
        let observing = { fixture.view.isObservingWindow }
        fixture.pane.presence.isPresented = false // its pane scrolled out of the strip, under a docked column
        #expect(!seen(), "a transcript off screen reports reads")
        #expect(!observing(), "a transcript off screen hears its window's notices")
        fixture.pane.presence.isPresented = true
        #expect(seen())
        #expect(observing())
    }

    /// No pane tab around it, no presence: a transcript a new container forgot to put in a tab is
    /// not seen, never seen by default.
    @Test func aTranscriptWithNoTabAroundItIsNotSeen() {
        let fixture = Self.fixture()
        defer { fixture.window.close() }
        let seen = { fixture.view.transcript.isVisibleToUser }
        let observing = { fixture.view.isObservingWindow }
        let loose = NSView(frame: fixture.pane.bounds)
        fixture.window.contentView?.addSubview(loose)
        loose.addSubview(fixture.view) // out of the tab, same window
        #expect(!seen(), "a transcript in no pane tab reports reads")
        #expect(!observing())
        fixture.pane.addSubview(fixture.view) // back into the tab
        #expect(seen())
        fixture.pane.presence.isPresented = false
        #expect(!seen())
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }

    /// A conversation tab reports reads only while a pane the layout reports on screen presents it:
    /// not before its pane presents it, not while that pane is scrolled out of the strip or covered
    /// (keep-alive or hidden presence), not after another tab of the pane is selected. The view comes
    /// from the one path a pane takes (`HomeService.tabView(for:)`), which gives it its tab's
    /// presence when it is made.
    @Test func aConversationTabIsSeenOnlyWhileAPaneOnScreenPresentsIt() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        var snapshot = TabSnapshot(surface: 4, kind: .conversation, title: "Chief")
        snapshot.conversation = ConversationTabRef(conversation: "conv_seen", owner: "home")
        let tab = TabModel(snapshot)
        let key = tab.id
        let made = services.home.tabView(for: tab)
        let home = try #require(made)
        defer { services.home.releaseTabView(key) }
        home.transcript.isWindowSeen = { _ in true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        window.contentView = container
        home.frame = container.bounds
        container.addSubview(home)
        home.layoutSubtreeIfNeeded()
        let seen = { home.transcript.transcript.isVisibleToUser }
        let observing = { home.transcript.isObservingWindow }
        #expect(!seen(), "a conversation tab no pane presents reports reads")
        #expect(!observing(), "a conversation tab no pane presents hears its window's notices")

        let pane = Pane()
        services.cache.present(key, by: pane, presence: .visible)
        #expect(seen(), "a conversation tab a pane on screen presents reports no reads")
        services.cache.setPresence(.keepAlive, presenter: pane) // scrolled out of the strip, under a docked column
        #expect(!seen(), "a conversation tab in a pane off screen reports reads")
        #expect(!observing())
        services.cache.setPresence(.hidden, presenter: pane) // a parked workspace, an inactive screen
        #expect(!seen())
        services.cache.setPresence(.visible, presenter: pane)
        #expect(seen())
        services.cache.withdraw(key, by: pane) // another tab of the pane selected
        #expect(!seen(), "a conversation tab its pane no longer shows reports reads")
    }

    /// The three ways a Home lives in a pane tab, each made by the path the app takes.
    enum HomeTab: String, CaseIterable, Sendable {
        /// An app-only `home.tab` (``InternalPageTabStore/open(_:in:of:after:window:key:)`` then
        /// ``InternalPageTabStore/view(for:)``): the tab id is the provider key.
        case appOnly
        /// A store `home.tab` (``InternalPageTabStore/view(forStoreTab:page:in:local:window:)``) whose
        /// provisional tab the store's tab replaces (``InternalPageTabStore/storeTabCreated(_:as:surface:)``).
        case storeTab
        /// The docked Home (``HomeDockTab``, `HomeDock.page`) as a store tab.
        case dock
    }

    /// A Home as a pane tab (`home.tab` app-only or from the store, the docked Home) holds a
    /// transcript too: the conversation it shows, and the New Message page's message box, report
    /// reads only while a pane on screen presents the tab: not at keep-alive or hidden presence, not
    /// once withdrawn, also across the store's tab replacing its provisional one.
    @Test(arguments: HomeTab.allCases)
    func aHomePaneTabIsSeenOnlyWhileAPaneOnScreenPresentsIt(_ kind: HomeTab) throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let pages = services.pages
        let page: InternalPageView
        var key: String
        var replaced: (provisional: String, real: String)?
        switch kind {
        case .appOnly:
            pages.register(HomePageTab(services: services))
            key = pages.open(.homeTab, in: "pane-home-seen", of: services.daemon.store)
            let made = pages.view(for: key)
            page = try #require(made)
        case .storeTab, .dock:
            let id: InternalPageID
            if kind == .dock {
                pages.register(HomeDockTab(services: services))
                id = .homeDock
            } else {
                pages.register(HomePageTab(services: services))
                id = .homeTab
            }
            var snapshot = TabSnapshot(surface: 7, tabResourceID: ResourceID(rawValue: "provisional-home-seen"),
                                       kind: .conversation, title: "Home")
            snapshot.conversation = ConversationTabRef(page: id.rawValue)
            let tab = TabModel(snapshot)
            key = tab.id
            let made = pages.view(forStoreTab: tab, in: services.daemon.store, window: nil)
            page = try #require(made)
            if kind == .storeTab { replaced = (tab.id, "home-seen-real") }
        }
        let content = (page.content as? HomeDockView)?.messages ?? page.content as? TopHomePageView
        let home = try #require(content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        window.contentView = container
        page.frame = container.bounds
        container.addSubview(page)
        home.show(ConversationID("conv_seen"))
        let shownHost = home.host
        let host = try #require(shownHost)
        host.transcript.isWindowSeen = { _ in true }
        host.transcript.windowStateChanged()
        let seen = { host.transcript.transcript.isVisibleToUser }
        let observing = { host.transcript.isObservingWindow }
        let composerPresented = { home.newMessage?.composer?.isPresented }
        #expect(!seen(), "a Home tab no pane presents reports reads")
        #expect(!observing(), "a Home tab no pane presents hears its window's notices")

        let pane = Pane()
        services.cache.present(key, by: pane, presence: .visible)
        #expect(seen(), "a Home tab a pane on screen presents reports no reads")
        if let replaced {
            // The store's tab replaces the provisional one: the pane presents the real id, then lets the provisional go.
            pages.storeTabCreated(replaced.provisional, as: replaced.real, surface: 8)
            services.cache.present(replaced.real, by: pane, presence: .visible)
            services.cache.withdraw(replaced.provisional, by: pane)
            key = replaced.real
            #expect(seen(), "a Home tab its store tab replaced is no longer seen")
        }
        services.cache.setPresence(.keepAlive, presenter: pane) // scrolled out of the strip, under a docked column
        #expect(!seen(), "a Home tab in a pane off screen reports reads")
        #expect(!observing(), "a Home tab in a pane off screen hears its window's notices")
        // A conversation shown while the pane is off screen starts not presented.
        home.show(ConversationID("conv_other"))
        let otherHost = home.host
        let other = try #require(otherHost)
        let otherPresented = { other.transcript.isPresented }
        #expect(!otherPresented(), "a conversation shown in a Home tab off screen counts as presented")
        home.presentNewMessage()
        #expect(composerPresented() == false, "the New Message box of a Home tab off screen counts as presented")
        services.cache.setPresence(.hidden, presenter: pane) // a parked workspace, an inactive screen
        #expect(!otherPresented())
        services.cache.setPresence(.visible, presenter: pane)
        #expect(otherPresented())
        #expect(composerPresented() == true)
        services.cache.withdraw(key, by: pane) // another tab of the pane selected
        #expect(!otherPresented(), "a Home tab its pane no longer shows reports reads")
        #expect(composerPresented() == false)
    }

    @Test func aTranscriptInAWindowNobodySeesIsNotSeen() {
        let fixture = Self.fixture()
        defer { fixture.window.close() }
        let seen = { fixture.view.transcript.isVisibleToUser }
        fixture.view.isWindowSeen = { _ in false }
        fixture.view.removeFromSuperview()
        fixture.pane.addSubview(fixture.view)
        #expect(!seen())
    }
}
