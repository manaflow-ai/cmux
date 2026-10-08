import Foundation
import Testing

@testable import CmuxBrowser

@Suite("Browser automation document state")
struct BrowserAutomationDocumentStateTests {
    private let checkout = UUID()
    private let docs = UUID()

    @Test("a selected frame applies to its own surface until the main frame is selected")
    func frameSelectionIsPerSurface() {
        var state = BrowserAutomationDocumentState()
        #expect(state.frameSelector(surfaceID: checkout) == nil)

        state.selectFrame("#checkout", surfaceID: checkout)
        #expect(state.frameSelector(surfaceID: checkout) == "#checkout")
        #expect(state.frameSelector(surfaceID: docs) == nil)

        state.selectMainFrame(surfaceID: checkout)
        #expect(state.frameSelector(surfaceID: checkout) == nil)
    }

    @Test("element refs resolve only on the surface they were found on")
    func elementRefsAreScopedToTheirSurface() {
        var state = BrowserAutomationDocumentState()
        let pay = state.allocateElementRef(selector: "#pay", surfaceID: checkout)
        let search = state.allocateElementRef(selector: "#search", surfaceID: docs)

        #expect(pay == "@e1")
        #expect(search == "@e2")
        #expect(state.selector(forElementRef: pay, surfaceID: checkout) == "#pay")
        #expect(state.selector(forElementRef: pay, surfaceID: docs) == nil)
        #expect(state.selector(forElementRef: "@e9", surfaceID: checkout) == nil)
    }

    @Test("closing a surface drops its frame and refs and leaves other surfaces alone")
    func removingASurfaceDropsOnlyItsState() {
        var state = BrowserAutomationDocumentState()
        state.selectFrame("#checkout", surfaceID: checkout)
        state.selectFrame("#sidebar", surfaceID: docs)
        let pay = state.allocateElementRef(selector: "#pay", surfaceID: checkout)
        let search = state.allocateElementRef(selector: "#search", surfaceID: docs)

        state.removeSurface(checkout)

        #expect(state.frameSelector(surfaceID: checkout) == nil)
        #expect(state.selector(forElementRef: pay, surfaceID: checkout) == nil)
        #expect(state.frameSelector(surfaceID: docs) == "#sidebar")
        #expect(state.selector(forElementRef: search, surfaceID: docs) == "#search")
    }
}
