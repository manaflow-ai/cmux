import AppKit
@testable import CmuxNextDesign
import Testing

/// The edge fade and the scroll fit follow their scroll view from its ``ScrollGeometryClipView`` hooks, not
/// frame or bounds notifications: a scroll, a clip resize and a document resize each
/// reach them in the same turn, with the clip's notifications left off.
@MainActor
@Suite(.serialized)
struct ScrollEdgeFadeTests {
    private static func scrollView(documentHeight: CGFloat) -> NSScrollView {
        _ = NSApplication.shared
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.contentInsets = NSEdgeInsetsZero
        scrollView.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 200, height: documentHeight))
        return scrollView
    }

    private static func window(showing view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 200, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    @Test func theFadeFollowsScrollsAndResizesFromTheClipHooks() throws {
        let scrollView = Self.scrollView(documentHeight: 400)
        // The clip's notifications off before the fade: scrolls and resizes reach it through the clip's hooks.
        scrollView.contentView.postsBoundsChangedNotifications = false
        scrollView.contentView.postsFrameChangedNotifications = false
        let fade = ScrollEdgeFadeView(scrollView: scrollView)
        let window = Self.window(showing: fade)
        defer { window.close() }
        let clip = try #require(scrollView.contentView as? ScrollGeometryClipView, "the fade did not install its clip")
        #expect(!clip.postsBoundsChangedNotifications && !clip.postsFrameChangedNotifications,
                "the fade turned the clip's notifications on")
        fade.updateFade(animated: false)
        #expect(fade.edges == [.bottom])

        clip.scroll(to: NSPoint(x: 0, y: 300))
        #expect(fade.edges == [.top], "a scroll to the end did not reach the fade")
        clip.scroll(to: NSPoint(x: 0, y: 150))
        #expect(fade.edges == [.top, .bottom])

        try #require(scrollView.documentView).setFrameSize(NSSize(width: 200, height: 80))
        #expect(fade.edges == [], "a document that now fits kept a fade")
    }

    @Test func theScrollFitFollowsTheDocumentAndTheClipFromTheClipHooks() throws {
        let scrollView = Self.scrollView(documentHeight: 60)
        scrollView.contentView.postsBoundsChangedNotifications = false
        scrollView.contentView.postsFrameChangedNotifications = false
        let fit = ScrollFitElasticity(scrollView: scrollView)
        let clip = try #require(scrollView.contentView as? ScrollGeometryClipView, "the fit did not install its clip")
        #expect(!clip.postsBoundsChangedNotifications && !clip.postsFrameChangedNotifications,
                "the fit turned the clip's notifications on")
        let document = try #require(scrollView.documentView)
        #expect(scrollView.verticalScrollElasticity == .none)

        document.setFrameSize(NSSize(width: 200, height: 300))
        #expect(scrollView.verticalScrollElasticity == .allowed, "a document that overflows did not bounce")

        scrollView.setFrameSize(NSSize(width: 200, height: 400))
        scrollView.tile()
        #expect(scrollView.verticalScrollElasticity == .none, "a clip that grew past the document still bounced")
        withExtendedLifetime(fit) {}
    }

    @Test func installingTheClipKeepsTheDocumentAndThePositionAndHappensOnce() throws {
        let scrollView = Self.scrollView(documentHeight: 400)
        scrollView.contentView.drawsBackground = false
        let document = try #require(scrollView.documentView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 120))

        let clip = ScrollGeometryClipView.install(in: scrollView)
        #expect(scrollView.contentView === clip)
        #expect(scrollView.documentView === document)
        #expect(clip.bounds.origin.y == 120)
        #expect(!clip.drawsBackground)
        #expect(ScrollGeometryClipView.install(in: scrollView) === clip, "a second install replaced the clip")
    }

    @Test func aScrollTellsOnlyAScrollAndAResizeTellsAResize() {
        let scrollView = Self.scrollView(documentHeight: 400)
        let clip = ScrollGeometryClipView.install(in: scrollView)
        let client = Recorder()
        clip.addClient(client)

        clip.scroll(to: NSPoint(x: 0, y: 40))
        #expect(client.changes == [.scrolled])
        clip.scroll(to: NSPoint(x: 0, y: 40))
        #expect(client.changes == [.scrolled], "a scroll to the same place told the clients")

        client.changes.removeAll()
        scrollView.documentView?.setFrameSize(NSSize(width: 200, height: 500))
        #expect(client.changes.contains(.resized), "a document resize did not reach the clients")
    }
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class Recorder: ScrollGeometryClient {
    var changes: [ScrollGeometryChange] = []
    func scrollGeometryDidChange(_ change: ScrollGeometryChange) { changes.append(change) }
}
