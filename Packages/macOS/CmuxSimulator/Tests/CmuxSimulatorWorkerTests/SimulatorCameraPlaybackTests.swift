import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator camera playback timing")
struct SimulatorCameraPlaybackTests {
    @Test("Finite video timestamps convert to bounded milliseconds")
    func boundedMilliseconds() {
        #expect(simulatorCameraFrameDelayMilliseconds(
            firstPresentationTime: 10,
            presentationTime: 11.234
        ) == 1_234)
        #expect(simulatorCameraFrameDelayMilliseconds(
            firstPresentationTime: 11,
            presentationTime: 10
        ) == 0)
    }

    @Test("Unrepresentable video timestamps are rejected before integer conversion")
    func rejectsUnrepresentableTimestamps() {
        #expect(simulatorCameraFrameDelayMilliseconds(
            firstPresentationTime: 0,
            presentationTime: .greatestFiniteMagnitude
        ) == nil)
        #expect(simulatorCameraFrameDelayMilliseconds(
            firstPresentationTime: 0,
            presentationTime: Double(Int64.max) / 1_000
        ) == nil)
        #expect(simulatorCameraFrameDelayMilliseconds(
            firstPresentationTime: .nan,
            presentationTime: 1
        ) == nil)
    }

    @Test("Loop pacing waits through a one-frame or empty track's asset duration")
    func loopPacingUsesPositiveAssetDuration() {
        #expect(simulatorCameraLoopDelayMilliseconds(
            assetDurationSeconds: 0.033
        ) == 33)
        #expect(simulatorCameraLoopDelayMilliseconds(
            assetDurationSeconds: 1
        ) == 1_000)
    }

    @Test("Loop pacing rejects tracks without a positive finite duration")
    func loopPacingRejectsInvalidDuration() {
        #expect(simulatorCameraLoopDelayMilliseconds(
            assetDurationSeconds: 0
        ) == nil)
        #expect(simulatorCameraLoopDelayMilliseconds(
            assetDurationSeconds: -1
        ) == nil)
        #expect(simulatorCameraLoopDelayMilliseconds(
            assetDurationSeconds: .nan
        ) == nil)
        #expect(simulatorCameraLoopDelayMilliseconds(
            assetDurationSeconds: .infinity
        ) == nil)
    }
}
