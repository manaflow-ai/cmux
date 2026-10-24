import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
@testable import MessagesLabHome
import Testing

/// A transcript counted as seen (`isVisibleToUser`, which reports reads) whenever its window was
/// key and on screen: a chat tab that is not selected, a parked workspace's chat and a pane scrolled
/// out of the strip all reported reads nobody saw, and every one of them answered each key and
/// occlusion notice of its window. Seen now means shown (no hidden flag of its own or an
/// ancestor's), partly inside its ancestors' bounds, in a window a person can see; a hidden
/// transcript hears no window notice.
///
/// Every check reads a plain value (a `Bool` from a closure, an optional local): a failing check describes
/// the values its expression captured, and describing a view walks its AppKit objects, which crashed
/// the runner (a CI Mac's compose field held a null pasteboard) instead of reporting the failure.
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

    @Test func aTranscriptScrolledOutOfItsAncestorsIsNotSeen() {
        let fixture = Self.fixture()
        defer { fixture.window.close() }
        let seen = { fixture.view.transcript.isVisibleToUser }
        // A pane scrolled out of the strip: in the window and shown, but outside every ancestor.
        fixture.pane.setFrameOrigin(NSPoint(x: 900, y: 0))
        // AppKit asks a view to update its tracking areas when its visible rect changes.
        fixture.view.updateTrackingAreas()
        #expect(!seen(), "a transcript out of sight reports reads")
        fixture.pane.setFrameOrigin(.zero)
        fixture.view.updateTrackingAreas()
        #expect(seen())
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
