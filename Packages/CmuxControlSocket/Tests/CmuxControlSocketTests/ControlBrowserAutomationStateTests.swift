import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("ControlBrowserAutomationState")
@MainActor
struct ControlBrowserAutomationStateTests {
    // MARK: - Element refs

    @Test func allocatesGlobalSequentialElementRefs() {
        let state = ControlBrowserAutomationState()
        let surfaceA = UUID()
        let surfaceB = UUID()
        // The ordinal is global across surfaces (legacy v2BrowserNextElementOrdinal).
        #expect(state.allocateElementRef(surfaceID: surfaceA, selector: "#a") == "@e1")
        #expect(state.allocateElementRef(surfaceID: surfaceB, selector: "#b") == "@e2")
        #expect(state.allocateElementRef(surfaceID: surfaceA, selector: "#c") == "@e3")
    }

    @Test func resolvesRefsOnlyOnTheirOwnSurface() {
        let state = ControlBrowserAutomationState()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let ref = state.allocateElementRef(surfaceID: surfaceA, selector: "#target")
        #expect(state.resolveSelector(ref, surfaceID: surfaceA) == "#target")
        // A bare `eN` spelling resolves too (legacy alias).
        #expect(state.resolveSelector(String(ref.dropFirst()), surfaceID: surfaceA) == "#target")
        // Foreign surface and unknown refs do not resolve.
        #expect(state.resolveSelector(ref, surfaceID: surfaceB) == nil)
        #expect(state.resolveSelector("@e99", surfaceID: surfaceA) == nil)
    }

    @Test func passesPlainSelectorsThroughTrimmed() {
        let state = ControlBrowserAutomationState()
        let surface = UUID()
        #expect(state.resolveSelector("  .button ", surfaceID: surface) == ".button")
        #expect(state.resolveSelector("   ", surfaceID: surface) == nil)
        // `e` followed by non-digits is a plain selector, not a ref.
        #expect(state.resolveSelector("em", surfaceID: surface) == "em")
    }

    // MARK: - Frame selectors

    @Test func frameSelectorSetAndClear() {
        let state = ControlBrowserAutomationState()
        let surface = UUID()
        #expect(state.frameSelector(forSurface: surface) == nil)
        state.setFrameSelector("#frame", forSurface: surface)
        #expect(state.frameSelector(forSurface: surface) == "#frame")
        state.setFrameSelector(nil, forSurface: surface)
        #expect(state.frameSelector(forSurface: surface) == nil)
    }

    // MARK: - Init scripts and styles

    @Test func initScriptAndStyleCountsGrowPerSurface() {
        let state = ControlBrowserAutomationState()
        let surface = UUID()
        #expect(state.appendInitScript("a()", forSurface: surface) == 1)
        #expect(state.appendInitScript("b()", forSurface: surface) == 2)
        #expect(state.appendInitStyle("body{}", forSurface: surface) == 1)
        #expect(state.initScripts(forSurface: surface) == ["a()", "b()"])
        #expect(state.initStyles(forSurface: surface) == ["body{}"])
    }

    // MARK: - Pending dialogs

    @Test func dialogQueueIsFIFOAndBoundedAt16() {
        let state = ControlBrowserAutomationState()
        let surface = UUID()
        var dialogs: [ControlBrowserPendingDialog] = []
        for index in 0..<18 {
            let dialog = ControlBrowserPendingDialog(
                dialogID: UUID(),
                surfaceID: surface,
                kind: "alert",
                message: "m\(index)",
                defaultText: nil
            )
            dialogs.append(dialog)
            let dropped = state.enqueueDialog(dialog)
            // The two overflow enqueues drop the oldest entry each.
            if index < 16 {
                #expect(dropped.isEmpty)
            } else {
                #expect(dropped == [dialogs[index - 16].dialogID])
            }
        }
        #expect(state.pendingDialogs(forSurface: surface).count == 16)
        // FIFO: the oldest surviving dialog pops first.
        #expect(state.popDialog(forSurface: surface)?.message == "m2")
        #expect(state.pendingDialogs(forSurface: surface).count == 15)
    }

    // MARK: - Cleanup

    @Test func purgeDropsAllPerSurfaceStateAndReportsDialogIDs() {
        let state = ControlBrowserAutomationState()
        let surface = UUID()
        let other = UUID()
        _ = state.allocateElementRef(surfaceID: surface, selector: "#a")
        let keptRef = state.allocateElementRef(surfaceID: other, selector: "#keep")
        state.setFrameSelector("#frame", forSurface: surface)
        _ = state.appendInitScript("a()", forSurface: surface)
        _ = state.appendInitStyle("body{}", forSurface: surface)
        let dialog = ControlBrowserPendingDialog(
            dialogID: UUID(),
            surfaceID: surface,
            kind: "confirm",
            message: "sure?",
            defaultText: "yes"
        )
        _ = state.enqueueDialog(dialog)

        let dropped = state.purgeSurfaceState(surfaceID: surface)
        #expect(dropped == [dialog.dialogID])
        #expect(state.resolveSelector("@e1", surfaceID: surface) == nil)
        #expect(state.frameSelector(forSurface: surface) == nil)
        #expect(state.initScripts(forSurface: surface).isEmpty)
        #expect(state.initStyles(forSurface: surface).isEmpty)
        #expect(state.pendingDialogs(forSurface: surface).isEmpty)
        // Other surfaces' refs survive.
        #expect(state.resolveSelector(keptRef, surfaceID: other) == "#keep")
    }
}
