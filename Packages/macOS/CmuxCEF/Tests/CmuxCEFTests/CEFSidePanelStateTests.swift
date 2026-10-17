import AppKit
import Foundation
import Testing
@testable import CmuxCEF

/// Chromium's side panel header (`cmux_side_panel_state`, fork API 13) as
/// cmux draws it over the page window.
@Suite
struct CEFSidePanelStateTests {
    private let openJSON = #"""
    {"open":true,"title":"Notes","icon_png":"","pin_visible":true,"pinned":false,
     "open_in_new_tab":false,"more_info":true,"focusable_controls":0,
     "header":{"x":880,"y":0,"width":320,"height":40}}
    """#

    @Test
    func decodesTheHeaderChromiumShows() throws {
        let state = try #require(CEFSidePanelState(json: openJSON))
        #expect(state.title == "Notes")
        #expect(state.icon == nil)
        #expect(state.showsPin && !state.isPinned)
        #expect(!state.showsOpenInNewTab)
        #expect(state.showsMoreInfo)
        #expect(state.chromiumFocusableControls == 0)
        #expect(state.header == CGRect(x: 880, y: 0, width: 320, height: 40))
        #expect(state.visibleControls == [.pin, .moreInfo, .close])
    }

    @Test
    func closedOrHeaderlessPanelHasNoState() {
        #expect(CEFSidePanelState(json: #"{"open":false}"#) == nil)
        #expect(CEFSidePanelState(json: #"{"open":true,"header":{"x":0,"y":0,"width":0,"height":40}}"#) == nil)
        #expect(CEFSidePanelState(json: "not json") == nil)
    }

    @Test
    func headerFrameIsMeasuredFromThePageWindowTop() throws {
        let state = try #require(CEFSidePanelState(json: openJSON))
        // A non-flipped host view: Chromium's y = 0 is the view's top edge.
        let frame = state.headerFrame(inPage: CGRect(x: 0, y: 0, width: 1200, height: 800))
        #expect(frame == CGRect(x: 880, y: 760, width: 320, height: 40))
    }

    @MainActor @Test
    func headerHoleSurvivesTheOwnersOcclusionRects() {
        let view = CEFHostView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let header = CGRect(x: 880, y: 760, width: 320, height: 40)
        view.sidePanelHeaderRect = header
        view.occlusionRects = [CGRect(x: 10, y: 10, width: 100, height: 30)]

        let holes = view.cmuxOcclusionRects().compactMap { ($0 as? NSValue)?.rectValue }
        // Holes come back merged into non-overlapping rects (the page's top
        // separator strip takes the header's top row), so the header is cut
        // out when the holes cover all of its area.
        let covered = holes.map { $0.intersection(header) }.filter { !$0.isNull }
            .reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        #expect(covered == header.width * header.height)
        #expect(holes.contains(CGRect(x: 10, y: 10, width: 100, height: 30)))

        view.sidePanelHeaderRect = nil
        let after = view.cmuxOcclusionRects().compactMap { ($0 as? NSValue)?.rectValue }
        #expect(!after.contains(header))
    }
}
