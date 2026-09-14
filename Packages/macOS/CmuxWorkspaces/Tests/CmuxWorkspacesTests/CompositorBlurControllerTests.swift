import Testing
@testable import CmuxWorkspaces

@Suite("Compositor blur controller")
struct CompositorBlurControllerTests {
    @Test("Resetting blur on an offscreen window number does not trap")
    func resetToleratesOffscreenWindowNumbers() {
        let controller = CompositorBlurController()
        // AppKit reports -1 for a window with no window-server window.
        controller.resetBackgroundBlur(windowNumber: -1)
        controller.resetBackgroundBlur(windowNumber: 0)
    }
}
