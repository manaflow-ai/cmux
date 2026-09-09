import Testing
@testable import CmuxWorkspaces

@Suite("CompositorBlurController")
struct CompositorBlurControllerTests {
    /// `NSWindow.windowNumber` is `<= 0` for a window without a window device.
    /// Converting such a value to the unsigned CGS window number traps, which
    /// crashed the app-host test suite whenever a backdrop was applied to a
    /// window that had never been ordered on screen.
    @Test("device-less window numbers are not reset")
    func deviceLessWindowNumbersAreSkipped() {
        #expect(!CompositorBlurController.canResetBackgroundBlur(windowNumber: -1))
        #expect(!CompositorBlurController.canResetBackgroundBlur(windowNumber: 0))
        #expect(CompositorBlurController.canResetBackgroundBlur(windowNumber: 1))
        #expect(CompositorBlurController.canResetBackgroundBlur(windowNumber: 4096))
    }

    @Test("resetting a device-less window number does not trap")
    func resettingDeviceLessWindowNumberDoesNotTrap() {
        let controller = CompositorBlurController()
        controller.resetBackgroundBlur(windowNumber: -1)
        controller.resetBackgroundBlur(windowNumber: 0)
    }
}
