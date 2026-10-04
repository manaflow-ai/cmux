import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextBrowser

/// cmux's side panel header (fork API 13) and popup window bounds.
@Suite struct SidePanelHeaderTests {
    @Test func openPanelStateDecodes() throws {
        let icon = Data([0x89, 0x50]).base64EncodedString()
        let json = """
        {"open":true,"title":"Reading list","icon_png":"\(icon)","pin_visible":true,"pinned":true,
         "open_in_new_tab":false,"more_info":true,"header":{"x":700,"y":80,"width":320,"height":40}}
        """
        let state = try #require(CEFSidePanelState(json: json))
        #expect(state.title == "Reading list")
        #expect(state.icon == Data([0x89, 0x50]))
        #expect(state.showsPin && state.isPinned && state.showsMoreInfo && !state.showsOpenInNewTab)
        #expect(state.header == CGRect(x: 700, y: 80, width: 320, height: 40))
    }

    /// Fork API 14: Chromium's own header buttons leave the focus order
    /// once cmux draws the header; the state counts those still in it.
    @Test func chromiumFocusableControlsDecode() throws {
        let json = #"{"open":true,"focusable_controls":0,"header":{"x":0,"y":0,"width":300,"height":40}}"#
        #expect(try #require(CEFSidePanelState(json: json)).chromiumFocusableControls == 0)
        let old = #"{"open":true,"header":{"x":0,"y":0,"width":300,"height":40}}"#
        #expect(try #require(CEFSidePanelState(json: old)).chromiumFocusableControls == nil)
    }

    @Test func closedPanelHasNoHeader() {
        #expect(CEFSidePanelState(json: #"{"open":false}"#) == nil)
        #expect(CEFSidePanelState(json: #"{"open":true,"header":{"x":0,"y":0,"width":0,"height":0}}"#) == nil)
        #expect(CEFSidePanelState(json: "not json") == nil)
    }

    /// The page view is not flipped: a header 80 DIPs below the page top
    /// sits 80 + height below the page's max Y.
    @Test func headerFrameIsInTheUnflippedPage() throws {
        let json = #"{"open":true,"header":{"x":700,"y":80,"width":320,"height":40}}"#
        let state = try #require(CEFSidePanelState(json: json))
        let frame = state.headerFrame(inPage: CGRect(x: 10, y: 20, width: 1020, height: 600))
        #expect(frame == CGRect(x: 710, y: 500, width: 320, height: 40))
    }

    /// The attached window follows the panel; the bounds event that move
    /// makes must not resize the panel again (the panel frame includes its
    /// title bar, so feeding it back makes the panel drift).
    @Test func ownPlacementBoundsAreIgnored() {
        let placed = CGRect(x: 100, y: 200, width: 400, height: 300)
        #expect(CEFPopupWindows.isOwnPlacement(placed, hostFrame: placed))
        #expect(CEFPopupWindows.isOwnPlacement(placed.offsetBy(dx: 0.5, dy: -0.5), hostFrame: placed))
        #expect(!CEFPopupWindows.isOwnPlacement(CGRect(x: 100, y: 200, width: 500, height: 300), hostFrame: placed))
        #expect(!CEFPopupWindows.isOwnPlacement(placed, hostFrame: nil))
    }
}
