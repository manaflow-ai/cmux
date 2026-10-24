import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextRemoteBrowser
import CmuxNextRemoteView
import Testing

#if DEBUG
/// A remote tab's popup surfaces (child panels of the page's window) are placed again when the
/// window comes back (occlusion, deminiaturize). Each remote tab with an open popup kept its own
/// observers of those notices; it now follows the window's ``WindowOcclusionFamily`` (one observer
/// per window, PATTERNS.md P3) while a surface is open, and leaves it when the last one goes.
@MainActor @Suite(.serialized) struct RemoteBrowserSurfacesOcclusionTests {
    /// A stream that never sends: the test checks placement, not pixels.
    private nonisolated final class StillSource: RemoteViewStreamSource {
        func accessUnits() -> AsyncStream<RemoteAccessUnit> { AsyncStream { $0.finish() } }
        func statusUpdates() -> AsyncStream<RemoteViewStatus> { AsyncStream { $0.finish() } }
        func cursorUpdates() -> AsyncStream<RemoteCursorState> { AsyncStream { $0.finish() } }
        func requestKeyframe() {}
    }

    @Test func anOpenSurfaceFollowsItsWindowsFamilyAndIsPlacedAgainOnItsNotice() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let center = NotificationCenter()
        let family = WindowOcclusionFamily.of(window, center: center)
        // The page sits in a container, so a container move shifts it in the window without a
        // frame change of its own (which would place the panels by itself).
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        try #require(window.contentView).addSubview(container)
        let page = RemoteBrowserContentView(frame: container.bounds)
        container.addSubview(page)
        window.orderFrontRegardless()
        let surfaces = RemoteBrowserSurfaces(page: page, source: { _ in StillSource() }, send: { _, _ in })
        defer { surfaces.closeAll(); window.orderOut(nil); window.close() }

        let anchor = CGRect(x: 10, y: 10, width: 100, height: 50)
        surfaces.apply(.show(surface: 1, stream: 1, kind: "page_popup", anchor: anchor, pixelWidth: 200, pixelHeight: 100))
        #expect(family.followerCount == 1, "the open surface kept occlusion observers of its own")
        let panel = try #require(surfaces.panel(of: 1))
        try #require(panel.parent === window, "the panel is not placed over the page (window visible: \(window.isVisible))")

        container.setFrameOrigin(NSPoint(x: 30, y: -40))
        let moved = window.convertToScreen(page.convert(anchor, to: nil))
        #expect(panel.frame != moved)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(panel.frame == moved, "the window's notice did not place the panel again")

        // The last surface gone: the family has no follower left and observes nothing.
        surfaces.apply(.hide(surface: 1))
        #expect(family.followerCount == 0)
        #expect(!family.isObserving)
    }
}
#endif
