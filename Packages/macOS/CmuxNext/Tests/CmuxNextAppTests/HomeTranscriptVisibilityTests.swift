import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
@testable import MessagesLabHome
import Testing

/// A transcript counted as seen (`isVisibleToUser`, which reports reads) whenever its window was
/// key and on screen: a chat tab that is not selected, a parked workspace's chat and a pane scrolled
/// out of the strip all reported reads nobody saw, and every one of them answered each key and
/// occlusion notice of its window. Seen now means shown (no hidden flag of its own or an
/// ancestor's), presented by a pane the layout reports on screen (a conversation tab), in a window
/// a person can see; a hidden transcript hears no window notice.
///
/// Geometry cannot say "on screen": a view's `visibleRect` is what its ancestors show in its own
/// coordinates, never empty for a pane moved out of the strip (no ancestor clips by default since
/// the macOS 14 SDK), and blind to the strip's layer masks (a pane under a docked column, clipped by
/// its nested area window) and to a pane faded to alpha 0. The layout's pane presence knows all of
/// them, and reaches the content cache's rendering set.
@MainActor @Suite(.serialized) struct HomeTranscriptVisibilityTests {
    private struct Fixture {
        let window: NSWindow
        let pane: NSView
        let view: HomeNativeTranscriptView
    }

    /// A transcript in a pane (`pane`) of a window a person sees.
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
        let pane = NSView(frame: container.bounds)
        container.addSubview(pane)
        view.frame = pane.bounds
        pane.addSubview(view)
        return Fixture(window: window, pane: pane, view: view)
    }

    @Test func aTranscriptUnderAHiddenAncestorIsNotSeen() {
        let fixture = Self.fixture()
        defer { fixture.window.close() }
        #expect(fixture.view.transcript.isVisibleToUser)
        fixture.pane.isHidden = true // a tab not selected, a parked workspace
        #expect(!fixture.view.transcript.isVisibleToUser, "a hidden transcript reports reads")
        #expect(!fixture.view.isObservingWindow, "a hidden transcript hears its window's notices")
        fixture.pane.isHidden = false
        #expect(fixture.view.transcript.isVisibleToUser)
        #expect(fixture.view.isObservingWindow)
    }

    @Test func aTranscriptMovedIntoAWindowUnderAHiddenAncestorIsNotSeen() {
        let fixture = Self.fixture()
        defer { fixture.window.close() }
        fixture.view.removeFromSuperview()
        fixture.pane.isHidden = true
        fixture.pane.addSubview(fixture.view)
        #expect(!fixture.view.transcript.isVisibleToUser)
        #expect(!fixture.view.isObservingWindow)
    }

    @Test func aTranscriptItsHostDoesNotPresentIsNotSeenAndHearsNoWindowNotice() {
        let fixture = Self.fixture()
        defer { fixture.window.close() }
        fixture.view.isPresented = false // its pane scrolled out of the strip, under a docked column
        #expect(!fixture.view.transcript.isVisibleToUser, "a transcript off screen reports reads")
        #expect(!fixture.view.isObservingWindow, "a transcript off screen hears its window's notices")
        fixture.view.isPresented = true
        #expect(fixture.view.transcript.isVisibleToUser)
        #expect(fixture.view.isObservingWindow)
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }

    /// A conversation tab reports reads only while a pane the layout reports on screen presents it:
    /// not before its pane presents it, not while that pane is scrolled out of the strip or covered
    /// (keep-alive or hidden presence), not after another tab of the pane is selected.
    @Test func aConversationTabIsSeenOnlyWhileAPaneOnScreenPresentsIt() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let key = "tab_seen"
        let home = HomeHostView(services: services, conversation: "conv_seen")
        home.transcript.isWindowSeen = { _ in true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        window.contentView = container
        home.frame = container.bounds
        services.home.tabViews[key] = home
        defer { services.home.tabViews[key] = nil }
        container.addSubview(home)
        home.layoutSubtreeIfNeeded()
        let seen = { home.transcript.transcript.isVisibleToUser }
        #expect(!seen(), "a conversation tab no pane presents reports reads")

        let pane = Pane()
        services.cache.present(key, by: pane, presence: .visible)
        #expect(seen(), "a conversation tab a pane on screen presents reports no reads")
        services.cache.setPresence(.keepAlive, presenter: pane) // scrolled out of the strip, under a docked column
        #expect(!seen(), "a conversation tab in a pane off screen reports reads")
        services.cache.setPresence(.hidden, presenter: pane) // a parked workspace, an inactive screen
        #expect(!seen())
        services.cache.setPresence(.visible, presenter: pane)
        #expect(seen())
        services.cache.withdraw(key, by: pane) // another tab of the pane selected
        #expect(!seen(), "a conversation tab its pane no longer shows reports reads")
    }

    @Test func aTranscriptInAWindowNobodySeesIsNotSeen() {
        let fixture = Self.fixture()
        defer { fixture.window.close() }
        fixture.view.isWindowSeen = { _ in false }
        fixture.view.removeFromSuperview()
        fixture.pane.addSubview(fixture.view)
        #expect(!fixture.view.transcript.isVisibleToUser)
    }
}
