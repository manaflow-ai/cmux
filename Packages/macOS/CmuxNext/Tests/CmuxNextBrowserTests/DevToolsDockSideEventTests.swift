import Testing
@testable import CmuxNextBrowser

/// Fork API v5: the DevTools menu's dock side arrives as tab event 8 and
/// maps to the pane's DevTools places.
@Suite struct DevToolsDockSideEventTests {
    @Test func decodesTheTabEvent() {
        let event = CEFShimEvent(kind: 16, browser: 7, request: 8, a: 3, b: 2, s1: "", s2: "")
        #expect(event == .tab(.devToolsDockSide, browser: 7, window: 3, value: 2))
    }

    @Test func mapsForkSides() {
        #expect(CEFTab.devToolsDock(forkSide: 0) == .window)
        #expect(CEFTab.devToolsDock(forkSide: 1) == .left)
        #expect(CEFTab.devToolsDock(forkSide: 2) == .bottom)
        #expect(CEFTab.devToolsDock(forkSide: 3) == .right)
    }
}
