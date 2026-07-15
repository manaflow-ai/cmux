import Darwin
import Foundation
import Testing
@testable import CmuxSimulator
@testable import CmuxSimulatorWorker

@Suite("Simulator camera surface containment")
struct SimulatorCameraSurfaceRingTests {
    @Test("Camera regions require the supervising client's private token")
    func distinctWorkerNames() {
        let device = "A1B2-C3D4"
        let first = simulatorCameraSharedMemoryName(
            deviceIdentifier: device,
            processIdentifier: 42,
            token: "first-private-token"
        )
        let second = simulatorCameraSharedMemoryName(
            deviceIdentifier: device,
            processIdentifier: 43,
            token: "first-private-token"
        )
        let otherDevice = simulatorCameraSharedMemoryName(
            deviceIdentifier: "FFFF-EEEE",
            processIdentifier: 42,
            token: "first-private-token"
        )
        let otherToken = simulatorCameraSharedMemoryName(
            deviceIdentifier: device,
            processIdentifier: 42,
            token: "second-private-token"
        )

        #expect(first != second)
        #expect(first != otherDevice)
        #expect(first != otherToken)
        #expect(first.hasPrefix("/cmux-sc-"))
        #expect(first.utf8.count < 31)
        #expect(second.utf8.count < 31)
        #expect(first == simulatorCameraSharedMemoryName(
            deviceIdentifier: device,
            processIdentifier: 42,
            token: "first-private-token"
        ))
    }

    @Test("Camera control shared memory is private")
    func cameraControlPermissions() throws {
        let ring = try SimulatorCameraSurfaceRing(
            deviceIdentifier: "PERMISSIONS-TEST",
            sharedMemoryToken: "permissions-private-token"
        )
        let descriptor = try simulatorOpenSharedMemory(
            named: ring.sharedMemoryName,
            flags: O_RDONLY
        )
        defer { close(descriptor) }
        var metadata = stat()

        #expect(descriptor >= 0)
        #expect(fstat(descriptor, &metadata) == 0)
        #expect(metadata.st_uid == geteuid())
        #expect(
            metadata.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
                == (S_IRUSR | S_IWUSR)
        )
        #expect(fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY)
        withExtendedLifetime(ring) {}
    }

    @Test("Camera sources aspect-fit by default instead of cropping")
    func cameraAspectFit() {
        let source = CGSize(width: 200, height: 100)
        let destination = CGSize(width: 100, height: 100)

        #expect(simulatorCameraImageScale(
            source: source,
            destination: destination,
            fillsFrame: false
        ) == 0.5)
        #expect(simulatorCameraImageScale(
            source: source,
            destination: destination,
            fillsFrame: true
        ) == 1)
    }

    @Test("Stopping a frame producer cancels its injected cadence deadline")
    @MainActor
    func producerStopCancelsCadence() async throws {
        let probe = CameraTimingProbe()
        let ring = try SimulatorCameraSurfaceRing(
            deviceIdentifier: "TIMING-TEST",
            sharedMemoryToken: "timing-private-token"
        )
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
