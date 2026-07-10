import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator camera surface containment")
struct SimulatorCameraSurfaceRingTests {
    @Test("Worker processes and devices receive distinct deterministic shared-memory names")
    func distinctWorkerNames() {
        let device = "A1B2-C3D4"
        let first = SimulatorCameraSurfaceRing.makeSharedMemoryName(
            deviceIdentifier: device,
            processIdentifier: 42
        )
        let second = SimulatorCameraSurfaceRing.makeSharedMemoryName(
            deviceIdentifier: device,
            processIdentifier: 43
        )
        let otherDevice = SimulatorCameraSurfaceRing.makeSharedMemoryName(
            deviceIdentifier: "FFFF-EEEE",
            processIdentifier: 42
        )

        #expect(first != second)
        #expect(first != otherDevice)
        #expect(first.hasPrefix("/cmux-sc-"))
        #expect(first.utf8.count < 31)
        #expect(second.utf8.count < 31)
        #expect(first == SimulatorCameraSurfaceRing.makeSharedMemoryName(
            deviceIdentifier: device,
            processIdentifier: 42
        ))
    }

    @Test("Camera sources aspect-fit by default instead of cropping")
    func cameraAspectFit() {
        let source = CGSize(width: 200, height: 100)
        let destination = CGSize(width: 100, height: 100)

        #expect(SimulatorCameraSurfaceRing.imageScale(
            source: source,
            destination: destination,
            fillsFrame: false
        ) == 0.5)
        #expect(SimulatorCameraSurfaceRing.imageScale(
            source: source,
            destination: destination,
            fillsFrame: true
        ) == 1)
    }

    @Test("Stopping a frame producer cancels its injected cadence deadline")
    @MainActor
    func producerStopCancelsCadence() async throws {
        let probe = CameraTimingProbe()
        let ring = try SimulatorCameraSurfaceRing(deviceIdentifier: "TIMING-TEST")
        let producer = SimulatorCameraFrameProducer(
            surfaceRing: ring,
            timing: TestCameraTiming(probe: probe)
        )

        try await producer.configure(.placeholder)
        for _ in 0..<1_000 {
            if await probe.hasStarted { break }
            try await ContinuousClock().sleep(for: .milliseconds(1))
        }
        try #require(await probe.hasStarted)
        await producer.stop()
        for _ in 0..<1_000 {
            if await probe.wasCancelled { break }
            try await ContinuousClock().sleep(for: .milliseconds(1))
        }

        #expect(await probe.wasCancelled)
    }
}

private struct TestCameraTiming: SimulatorCameraTiming {
    let probe: CameraTimingProbe

    func now() -> Duration { .zero }

    func sleep(for duration: Duration) async throws {
        try await probe.sleep()
    }

    func sleep(until deadline: Duration, tolerance: Duration) async throws {
        try await probe.sleep()
    }
}

private actor CameraTimingProbe {
    private var started = false
    private var cancelled = false

    var hasStarted: Bool { started }
    var wasCancelled: Bool { cancelled }

    func sleep() async throws {
        started = true
        do {
            try await ContinuousClock().sleep(for: .seconds(3_600))
        } catch {
            cancelled = true
            throw error
        }
    }
}
