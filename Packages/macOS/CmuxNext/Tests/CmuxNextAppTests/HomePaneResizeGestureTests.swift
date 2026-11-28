import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import CmuxNextTestSupport
@testable import MessagesLabHome
import Testing

/// A divider or edge drag, and a window's live resize, tell the pane contents that follow them
/// (``PaneResizeGestureFollowing``, `ScreenContentView+ResizeGesture`) the start and the landing. Home followed neither:
/// its host took its live-resize paths only for AppKit's window live resize, so in a divider drag Home's empty field was
/// resized and rewrapped at every width (release-resize bp-on-2, 2026-11-26). Home's pane content now follows the drag:
/// its host is in a live resize from the drag's start to its landing (`MessagesLabHomeView.followPaneResize`).
@MainActor @Suite(.serialized, .closesItsWindows) struct HomePaneResizeGestureTests {
    private func home() -> (NSWindow, NSView, HomeNativeTranscriptView) {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        let view = HomeNativeTranscriptView(store: store, conversation: ConversationID("conv_pane_drag"), me: ParticipantID("user_me"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        return (window, container, view)
    }

    @Test func homeHearsADragOfItsPane() {
        let (window, container, view) = home()
        defer { window.close() }
        let heard = container.paneResizeGestureFollowers().contains { $0 === view }
        #expect(heard, "Home's pane content is not told a divider drag of its pane")
    }

    @Test func theDragsStartAndLandingReachHomesHost() {
        let (window, container, view) = home()
        defer { window.close() }
        let host = view.transcript.controller.host
        let followers = container.paneResizeGestureFollowers()
        for follower in followers { follower.paneResizeGestureDidChange(active: true) }
        let followedStart = host.paneLiveResize
        for follower in followers { follower.paneResizeGestureDidChange(active: false) }
        let followedEnd = !host.paneLiveResize
        #expect(followedStart, "the drag's start left Home's host outside a live resize")
        #expect(followedEnd, "the drag's landing left Home's host in a live resize")
    }
}
