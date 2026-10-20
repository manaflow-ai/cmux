import CmuxSimulator
import Testing

@testable import CmuxSimulatorWorker

@Suite("Simulator framebuffer target sizing")
struct SimulatorFramebufferTargetSizeTests {
    @Test("Native iPad frames are bounded to the pane backing size")
    func boundsNativeIPadFrame() {
        let size = SimulatorFramebufferTargetSize(
            sourceWidth: 2_064,
            sourceHeight: 2_752,
            geometry: SimulatorSurfaceGeometry(width: 400, height: 530, scale: 2)
        )

        #expect(size.width == 795)
        #expect(size.height == 1_060)
    }

    @Test("Publication never upscales the native framebuffer")
    func avoidsUpscaling() {
        let size = SimulatorFramebufferTargetSize(
            sourceWidth: 1_290,
            sourceHeight: 2_796,
            geometry: SimulatorSurfaceGeometry(width: 2_000, height: 3_000, scale: 2)
        )

        #expect(size.width == 1_290)
        #expect(size.height == 2_796)
    }

    @Test("Missing geometry preserves the native framebuffer")
    func preservesNativeSizeWithoutGeometry() {
        let size = SimulatorFramebufferTargetSize(
            sourceWidth: 2_064,
            sourceHeight: 2_752,
            geometry: nil
        )

        #expect(size.width == 2_064)
        #expect(size.height == 2_752)
    }
}
