@testable import CmuxAndroidEmulator
import Foundation
import Testing

@MainActor
@Suite struct AndroidEmulatorCoordinatorTests {
    @Test func successfulLaunchClearsPendingState() async {
        let service = StubAndroidEmulatorService(
            snapshots: [.success(Self.snapshot)]
        )
        let coordinator = AndroidEmulatorCoordinator(service: service)

        await coordinator.launch(avdName: "Pixel_9_API_35")

        #expect(coordinator.launchingAVDNames.isEmpty)
    }

    @Test func successfulStopClearsPendingStateWhenRefreshFails() async {
        let service = StubAndroidEmulatorService(
            snapshots: [.failure(.commandFailed(tool: "adb", detail: "offline"))]
        )
        let coordinator = AndroidEmulatorCoordinator(service: service)

        await coordinator.stop(serial: "emulator-5554")

        #expect(coordinator.stoppingSerials.isEmpty)
    }

    private static let snapshot = AndroidEmulatorSnapshot(
        sdkRootURL: URL(fileURLWithPath: "/sdk", isDirectory: true),
        devices: [AndroidVirtualDevice(name: "Pixel_9_API_35", state: .stopped)],
        warning: nil
    )
}

private actor StubAndroidEmulatorService: AndroidEmulatorServicing {
    private var snapshots: [Result<AndroidEmulatorSnapshot, AndroidEmulatorError>]

    init(snapshots: [Result<AndroidEmulatorSnapshot, AndroidEmulatorError>]) {
        self.snapshots = snapshots
    }

    func snapshot() async throws -> AndroidEmulatorSnapshot {
        guard !snapshots.isEmpty else {
            return AndroidEmulatorSnapshot(
                sdkRootURL: URL(fileURLWithPath: "/sdk", isDirectory: true),
                devices: [],
                warning: nil
            )
        }
        return try snapshots.removeFirst().get()
    }

    func launch(avdName: String) async throws {
        _ = avdName
    }

    func stop(serial: String) async throws {
        _ = serial
    }
}
