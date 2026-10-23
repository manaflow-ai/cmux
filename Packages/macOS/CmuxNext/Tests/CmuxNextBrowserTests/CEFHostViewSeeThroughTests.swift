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

    /// A Chromium page resize no longer holds the app's commit (`CEFSwitches`), so the page window
    /// trails its host on every resize: a divider drag or a split spring that widens the pane shows
    /// the host at the growing edge until Chromium's frame at the new size arrives. Outside a window
    /// live resize that gap showed the pane ground (a dark band beside a white page) instead of the
    /// page's own background.
    @Test func aKnownPageBackdropFillsTheHostOutsideAWindowLiveResize() throws {
        let view = CEFHostView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        // Pure red: no theme's pane ground is this color.
        let backdrop = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        #expect(!view.inLiveResize)
        view.pageBackdrop = backdrop
        #expect(try #require(view.layer).backgroundColor == backdrop)
        // No known page background (a new document before its first real page): the pane ground.
        view.pageBackdrop = nil
        #expect(try #require(view.layer).backgroundColor != backdrop)
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
