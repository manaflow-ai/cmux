import CoreGraphics
import Testing
@testable import CmuxNextBrowser

/// The agent cursor maps viewport CSS px into the page's own viewport: an
/// open Chromium side panel shares the page window and takes its column.
@Suite struct SidePanelViewportTests {
    private let page = CGRect(x: 0, y: 0, width: 1020, height: 700)

    @Test func aRightPanelLeavesTheContentsOnTheLeft() throws {
        let state = try #require(CEFSidePanelState(json: #"{"open":true,"header":{"x":700,"y":0,"width":320,"height":40}}"#))
        #expect(state.contentsFrame(inPage: page) == CGRect(x: 0, y: 0, width: 700, height: 700))
    }

    @Test func aLeftPanelLeavesTheContentsOnTheRight() throws {
        let state = try #require(CEFSidePanelState(json: #"{"open":true,"header":{"x":0,"y":0,"width":300,"height":40}}"#))
        #expect(state.contentsFrame(inPage: page) == CGRect(x: 300, y: 0, width: 720, height: 700))
    }

    @Test func anOffsetPageKeepsItsOrigin() throws {
        let state = try #require(CEFSidePanelState(json: #"{"open":true,"header":{"x":700,"y":0,"width":320,"height":40}}"#))
        let shifted = page.offsetBy(dx: 50, dy: 20)
        #expect(state.contentsFrame(inPage: shifted) == CGRect(x: 50, y: 20, width: 700, height: 700))
    }
}
