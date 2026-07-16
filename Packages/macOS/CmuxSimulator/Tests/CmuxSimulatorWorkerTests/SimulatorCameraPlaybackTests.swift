import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator camera playback timing")
struct SimulatorCameraPlaybackTests {
    @Test("Finite video timestamps convert to bounded milliseconds")
    func boundedMilliseconds() {
        #expect(SimulatorCameraPlayback.delayMilliseconds(
            firstPresentationTime: 10,
            presentationTime: 11.234
        ) == 1_234)
        #expect(SimulatorCameraPlayback.delayMilliseconds(
            firstPresentationTime: 11,
            presentationTime: 10
        ) == 0)
    }

    @Test("Unrepresentable video timestamps are rejected before integer conversion")
    func rejectsUnrepresentableTimestamps() {
        #expect(SimulatorCameraPlayback.delayMilliseconds(
            firstPresentationTime: 0,
            presentationTime: .greatestFiniteMagnitude
        ) == nil)
        #expect(SimulatorCameraPlayback.delayMilliseconds(
            firstPresentationTime: 0,
            presentationTime: Double(Int64.max) / 1_000
        ) == nil)
        #expect(SimulatorCameraPlayback.delayMilliseconds(
            firstPresentationTime: .nan,
            presentationTime: 1
        ) == nil)
    }
}
