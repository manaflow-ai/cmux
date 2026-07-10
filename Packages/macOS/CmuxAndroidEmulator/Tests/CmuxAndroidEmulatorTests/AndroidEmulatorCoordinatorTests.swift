@testable import CmuxAndroidEmulator
import Foundation
import Testing

@MainActor
@Suite struct AndroidEmulatorCoordinatorTests {
    @Test func launchRemainsPendingUntilRefreshConfirmsRunning() async {
        let service = StubAndroidEmulatorService(
            snapshots: [
                .success(Self.snapshot),
                .success(Self.runningSnapshot),
            ]
        )
        let delay = TestActionConfirmationDelay()
        let coordinator = AndroidEmulatorCoordinator(
            service: service,
            actionConfirmationTimeout: .seconds(30),
            sleep: { duration in try await delay.sleep(for: duration) }
        )

        let launchTask = Task { await coordinator.launch(avdName: "Pixel_9_API_35") }
        await delay.waitUntilSleeping()

        #expect(coordinator.launchingAVDNames == ["Pixel_9_API_35"])

        await coordinator.refresh()
        await delay.release()
        await launchTask.value

        #expect(coordinator.launchingAVDNames.isEmpty)
        #expect(coordinator.loadState == .loaded(Self.runningSnapshot))
    }

    @Test func unconfirmedLaunchSurfacesDeadlineFailure() async {
        let service = StubAndroidEmulatorService(snapshots: [.success(Self.snapshot)])
        let coordinator = AndroidEmulatorCoordinator(
            service: service,
            actionConfirmationTimeout: .zero,
            sleep: { _ in }
        )

        await coordinator.launch(avdName: "Pixel_9_API_35")

        #expect(coordinator.launchingAVDNames.isEmpty)
        #expect(coordinator.actionError == .launchNotConfirmed(name: "Pixel_9_API_35"))
    }

    @Test func unconfirmedStopSurfacesDeadlineFailureWhenRefreshFails() async {
        let service = StubAndroidEmulatorService(
            snapshots: [.failure(.commandFailed(tool: "adb", detail: "offline"))]
        )
        let coordinator = AndroidEmulatorCoordinator(
            service: service,
            actionConfirmationTimeout: .zero,
            sleep: { _ in }
        )

        await coordinator.stop(serial: "emulator-5554")

        #expect(coordinator.stoppingSerials.isEmpty)
        #expect(coordinator.actionError == .stopNotConfirmed(serial: "emulator-5554"))
    }

    private static let snapshot = AndroidEmulatorSnapshot(
        sdkRootURL: URL(fileURLWithPath: "/sdk", isDirectory: true),
        devices: [AndroidVirtualDevice(name: "Pixel_9_API_35", state: .stopped)],
        warning: nil
    )

    private static let runningSnapshot = AndroidEmulatorSnapshot(
        sdkRootURL: URL(fileURLWithPath: "/sdk", isDirectory: true),
        devices: [AndroidVirtualDevice(
            name: "Pixel_9_API_35",
            state: .running(serial: "emulator-5554", connectionState: "device")
        )],
        warning: nil
    )
}

private actor TestActionConfirmationDelay {
    private var didStartSleeping = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func sleep(for duration: Duration) async throws {
        _ = duration
        didStartSleeping = true
        startContinuation?.resume()
        startContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSleeping() async {
        if didStartSleeping { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
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
