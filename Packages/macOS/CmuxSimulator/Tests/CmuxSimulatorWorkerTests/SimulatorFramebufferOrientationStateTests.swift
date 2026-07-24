import CmuxSimulator
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator framebuffer orientation state")
struct SimulatorFramebufferOrientationStateTests {
    @Test("Native orientation dialects map through logical orientation")
    func mapsNativeOrientationDialects() {
        #expect(SimulatorNativeOrientationCodec.purpleWorkspaceRawValue(for: .portrait) == 1)
        #expect(SimulatorNativeOrientationCodec.purpleWorkspaceRawValue(for: .portraitUpsideDown) == 2)
        #expect(SimulatorNativeOrientationCodec.purpleWorkspaceRawValue(for: .landscapeRight) == 3)
        #expect(SimulatorNativeOrientationCodec.purpleWorkspaceRawValue(for: .landscapeLeft) == 4)

        #expect(SimulatorNativeOrientationCodec.screenOrientation(rawValue: 1) == .portrait)
        #expect(SimulatorNativeOrientationCodec.screenOrientation(rawValue: 2) == .portraitUpsideDown)
        #expect(SimulatorNativeOrientationCodec.screenOrientation(rawValue: 3) == .landscapeLeft)
        #expect(SimulatorNativeOrientationCodec.screenOrientation(rawValue: 4) == .landscapeRight)
        #expect(SimulatorNativeOrientationCodec.screenOrientation(rawValue: 0) == nil)
    }

    @Test("An already-landscape framebuffer attaches in its native orientation")
    func attachesToLandscapeDisplay() {
        var nativeState = SimulatorFramebufferOrientationState()
        let nativeOrientation = nativeState.observe(
            width: 2_796,
            height: 1_290,
            nativeRawValue: 3
        )
        let nativeGeometry = SimulatorOrientationGeometry(
            rawWidth: 2_796,
            rawHeight: 1_290,
            requestedOrientation: nativeOrientation
        )

        var fallbackState = SimulatorFramebufferOrientationState()
        let fallbackOrientation = fallbackState.observe(
            width: 2_796,
            height: 1_290,
            nativeRawValue: nil
        )
        let fallbackGeometry = SimulatorOrientationGeometry(
            rawWidth: 2_796,
            rawHeight: 1_290,
            requestedOrientation: fallbackOrientation
        )

        #expect(nativeOrientation == .landscapeLeft)
        #expect(!nativeGeometry.needsRawTransform)
        #expect(fallbackOrientation == .landscapeLeft)
        #expect(!fallbackGeometry.needsRawTransform)
    }

    @Test("SimulatorKit property changes replace stale orientation without a shape change")
    func observesExternalRotation() {
        var state = SimulatorFramebufferOrientationState()

        #expect(state.observe(width: 1_290, height: 2_796, nativeRawValue: 1) == .portrait)
        #expect(state.observe(width: 1_290, height: 2_796, nativeRawValue: 2) == .portraitUpsideDown)
        #expect(state.observe(width: 2_796, height: 1_290, nativeRawValue: 3) == .landscapeLeft)
        #expect(state.observe(width: 2_796, height: 1_290, nativeRawValue: 4) == .landscapeRight)

        state.request(.portrait)
        #expect(state.observe(
            width: 2_796,
            height: 1_290,
            nativeRawValue: 4,
            nativeValueIsAuthoritative: true
        ) == .landscapeRight)
    }

    @Test("A requested rotation survives stale native properties until the surface catches up")
    func preservesPendingRotation() {
        var state = SimulatorFramebufferOrientationState()
        _ = state.observe(width: 1_290, height: 2_796, nativeRawValue: 1)

        state.request(.landscapeRight)
        let pendingOrientation = state.observe(
            width: 1_290,
            height: 2_796,
            nativeRawValue: 1
        )
        let pendingGeometry = SimulatorOrientationGeometry(
            rawWidth: 1_290,
            rawHeight: 2_796,
            requestedOrientation: pendingOrientation
        )

        let settledOrientation = state.observe(
            width: 2_796,
            height: 1_290,
            nativeRawValue: 4
        )
        let settledGeometry = SimulatorOrientationGeometry(
            rawWidth: 2_796,
            rawHeight: 1_290,
            requestedOrientation: settledOrientation
        )

        #expect(pendingOrientation == .landscapeRight)
        #expect(pendingGeometry.presentationRotationDegrees == 90)
        #expect(settledOrientation == .landscapeRight)
        #expect(!settledGeometry.needsRawTransform)
    }

    @Test("PurpleWorkspace requests and SimulatorKit callbacks preserve logical landscape identity")
    func reconcilesPrivateOrientationDialects() {
        var state = SimulatorFramebufferOrientationState()

        state.request(.landscapeRight)
        #expect(state.observe(
            width: 1_290,
            height: 2_796,
            nativeRawValue: 1
        ) == .landscapeRight)
        #expect(state.observe(
            width: 1_290,
            height: 2_796,
            nativeRawValue: 4,
            nativeValueIsAuthoritative: true
        ) == .landscapeRight)

        state.request(.landscapeLeft)
        #expect(state.observe(
            width: 1_290,
            height: 2_796,
            nativeRawValue: 3,
            nativeValueIsAuthoritative: true
        ) == .landscapeLeft)
    }
}
