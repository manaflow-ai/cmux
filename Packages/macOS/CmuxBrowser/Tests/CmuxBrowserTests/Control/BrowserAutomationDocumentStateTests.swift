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

        state.selectFrame("#checkout", surfaceID: checkout, checkedInDocument: state.documentGeneration(surfaceID: checkout))
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
        state.selectFrame("#checkout", surfaceID: checkout, checkedInDocument: state.documentGeneration(surfaceID: checkout))
        state.selectFrame("#sidebar", surfaceID: docs, checkedInDocument: state.documentGeneration(surfaceID: docs))
        let pay = state.allocateElementRef(selector: "#pay", surfaceID: checkout)
        let search = state.allocateElementRef(selector: "#search", surfaceID: docs)

        state.removeSurface(checkout)

        #expect(state.frameSelector(surfaceID: checkout) == nil)
        #expect(state.selector(forElementRef: pay, surfaceID: checkout) == nil)
        #expect(state.frameSelector(surfaceID: docs) == "#sidebar")
        #expect(state.selector(forElementRef: search, surfaceID: docs) == "#search")
    }

    /// The selected frame is a selector in the old page. Kept across a
    /// navigation it either matches nothing, and commands silently run in the
    /// new top document, or it matches an unrelated frame.
    @Test("a main-frame commit returns the surface to the main frame")
    func mainFrameCommitDropsTheSelectedFrame() {
        var state = BrowserAutomationDocumentState()
        state.selectFrame("#checkout", surfaceID: checkout, checkedInDocument: state.documentGeneration(surfaceID: checkout))
        state.selectFrame("#sidebar", surfaceID: docs, checkedInDocument: state.documentGeneration(surfaceID: docs))

        state.mainFrameDidCommit(surfaceID: checkout)

        #expect(state.frameSelector(surfaceID: checkout) == nil)
        #expect(state.frameSelector(surfaceID: docs) == "#sidebar")
    }

    @Test("a main-frame commit invalidates the surface's element refs for good")
    func mainFrameCommitDropsElementRefs() {
        var state = BrowserAutomationDocumentState()
        let pay = state.allocateElementRef(selector: "#pay", surfaceID: checkout)
        let search = state.allocateElementRef(selector: "#search", surfaceID: docs)

        state.mainFrameDidCommit(surfaceID: checkout)

        #expect(state.selector(forElementRef: pay, surfaceID: checkout) == nil)
        #expect(state.selector(forElementRef: search, surfaceID: docs) == "#search")

        // A ref from the old page must not come back to life for an element of the new one.
        let next = state.allocateElementRef(selector: "#cancel", surfaceID: checkout)
        #expect(next != pay)
        #expect(state.selector(forElementRef: pay, surfaceID: checkout) == nil)
        #expect(state.selector(forElementRef: next, surfaceID: checkout) == "#cancel")
    }

    /// `frame select` checks its selector in the page before storing it. A
    /// redirect that commits during that check must not leave the selector
    /// stored for the page it was never checked in.
    @Test("a frame checked in a document that has since been replaced is not selected")
    func frameCheckedInAReplacedDocumentIsRefused() {
        var state = BrowserAutomationDocumentState()
        let checkedIn = state.documentGeneration(surfaceID: checkout)

        state.mainFrameDidCommit(surfaceID: checkout)

        let selectedStale = state.selectFrame("#checkout", surfaceID: checkout, checkedInDocument: checkedIn)
        #expect(!selectedStale)
        #expect(state.frameSelector(surfaceID: checkout) == nil)

        let current = state.documentGeneration(surfaceID: checkout)
        let selectedCurrent = state.selectFrame("#checkout", surfaceID: checkout, checkedInDocument: current)
        #expect(selectedCurrent)
        #expect(state.frameSelector(surfaceID: checkout) == "#checkout")
        #expect(state.documentGeneration(surfaceID: docs) == checkedIn)
    }
}
