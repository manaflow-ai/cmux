import AppKit
@testable import CmuxNextBrowser
import Testing

/// The parent view of a Chromium page window shows wherever the page draws nothing. Under a
/// see-through cmux page it must paint nothing itself, or the page reads as an opaque slab over
/// the pane and the window backdrop (user report 2026-10-21, Home chat).
@MainActor
@Suite struct CEFHostViewSeeThroughTests {
    @Test func aWebPageHostPaintsThePaneGround() throws {
        let view = CEFHostView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        #expect(try #require(view.layer).backgroundColor != nil)
    }

    @Test func aSeeThroughPageHostPaintsNothing() throws {
        let view = CEFHostView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        view.pageSeeThrough = true
        #expect(try #require(view.layer).backgroundColor == nil)
        // A live resize's backdrop color is for opaque web pages only.
        view.pageBackdrop = NSColor.red.cgColor
        #expect(try #require(view.layer).backgroundColor == nil)
    }
}
