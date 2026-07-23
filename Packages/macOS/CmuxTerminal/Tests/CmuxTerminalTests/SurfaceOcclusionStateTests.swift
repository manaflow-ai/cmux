import Testing
@testable import CmuxTerminal

@Suite struct SurfaceOcclusionStateTests {
    @Test func defaultsAreVisibleOnBothAxes() {
        let state = SurfaceOcclusionState()

        #expect(state.uiVisible)
        #expect(state.windowVisible)
        #expect(state.effectiveVisible)
    }

    @Test(arguments: [
        (uiVisible: true, windowVisible: true, effectiveVisible: true),
        (uiVisible: true, windowVisible: false, effectiveVisible: false),
        (uiVisible: false, windowVisible: true, effectiveVisible: false),
        (uiVisible: false, windowVisible: false, effectiveVisible: false)
    ])
    func effectiveVisibilityIsTheAndOfBothAxes(
        uiVisible: Bool,
        windowVisible: Bool,
        effectiveVisible: Bool
    ) {
        let state = SurfaceOcclusionState(uiVisible: uiVisible, windowVisible: windowVisible)

        #expect(state.effectiveVisible == effectiveVisible)
    }

    @Test func uiVisibilityMustReturnBeforeWindowVisibilityCanRenderAgain() {
        var state = SurfaceOcclusionState()

        state.uiVisible = false
        #expect(!state.effectiveVisible)

        state.windowVisible = false
        #expect(!state.effectiveVisible)

        state.windowVisible = true
        #expect(!state.effectiveVisible)

        state.uiVisible = true
        #expect(state.effectiveVisible)
    }
}
