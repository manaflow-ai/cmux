@testable import CmuxAndroidEmulator
import Foundation
import Testing

@MainActor
@Suite struct AndroidEmulatorCoordinatorTests {
    @Test func launchRemainsPendingUntilServiceConfirmsRunning() async {
        let service = StubAndroidEmulatorService(
            snapshots: [.success(Self.runningSnapshot)],
            blockLaunch: true
        )
        let coordinator = AndroidEmulatorCoordinator(service: service)

        let launchTask = Task { await coordinator.launch(avdName: "Pixel_9_API_35") }
        await service.waitUntilLaunchStarted()

        #expect(coordinator.launchingAVDNames == ["Pixel_9_API_35"])

        await service.releaseLaunch()
        await launchTask.value

        #expect(coordinator.launchingAVDNames.isEmpty)
        #expect(coordinator.loadState == .loaded(Self.runningSnapshot))
    }

    @Test func unconfirmedLaunchSurfacesServiceFailure() async {
        let service = StubAndroidEmulatorService(
            snapshots: [],
            launchError: .launchNotConfirmed(name: "Pixel_9_API_35")
        )
        let coordinator = AndroidEmulatorCoordinator(service: service)

        await coordinator.launch(avdName: "Pixel_9_API_35")

        #expect(coordinator.launchingAVDNames.isEmpty)
        #expect(coordinator.actionError == .launchNotConfirmed(name: "Pixel_9_API_35"))
    }

    @Test func unconfirmedStopSurfacesServiceFailure() async {
        let service = StubAndroidEmulatorService(
            snapshots: [],
            stopError: .stopNotConfirmed(serial: "emulator-5554")
        )
        let coordinator = AndroidEmulatorCoordinator(service: service)

        await coordinator.stop(serial: "emulator-5554")

        #expect(coordinator.stoppingSerials.isEmpty)
        #expect(coordinator.actionError == .stopNotConfirmed(serial: "emulator-5554"))
    }

    @Test func unavailableSnapshotDoesNotConfirmPendingStop() async {
        let service = StubAndroidEmulatorService(
            snapshots: [.success(Self.unavailableSnapshot)],
            blockStop: true
        )
        let coordinator = AndroidEmulatorCoordinator(service: service)

        let stopTask = Task { await coordinator.stop(serial: "emulator-5554") }
        await service.waitUntilStopStarted()
        await coordinator.refresh()

        #expect(coordinator.stoppingSerials == ["emulator-5554"])

        await service.releaseStop()
        await stopTask.value
        #expect(coordinator.stoppingSerials.isEmpty)
    }

    private static let runningSnapshot = AndroidEmulatorSnapshot(
        sdkRootURL: URL(fileURLWithPath: "/sdk", isDirectory: true),
        devices: [AndroidVirtualDevice(
            name: "Pixel_9_API_35",
            state: .running(serial: "emulator-5554", connectionState: "device")
        )],
        warning: nil,
        connectedEmulatorSerials: ["emulator-5554"]
    )

    private static let unavailableSnapshot = AndroidEmulatorSnapshot(
        sdkRootURL: URL(fileURLWithPath: "/sdk", isDirectory: true),
        devices: [AndroidVirtualDevice(name: "Pixel_9_API_35", state: .unavailable)],
        warning: .adbQueryFailed(detail: "offline"),
        connectedEmulatorSerials: nil
    )
}

private actor StubAndroidEmulatorService: AndroidEmulatorServicing {
    private var snapshots: [Result<AndroidEmulatorSnapshot, AndroidEmulatorError>]
    private let launchError: AndroidEmulatorError?
    private let stopError: AndroidEmulatorError?
    private let blockLaunch: Bool
    private let blockStop: Bool
    private var launchStarted = false
    private var stopStarted = false
    private var launchStartContinuation: CheckedContinuation<Void, Never>?
    private var stopStartContinuation: CheckedContinuation<Void, Never>?
    private var launchReleaseContinuation: CheckedContinuation<Void, Never>?
    private var stopReleaseContinuation: CheckedContinuation<Void, Never>?

    init(
        snapshots: [Result<AndroidEmulatorSnapshot, AndroidEmulatorError>],
        launchError: AndroidEmulatorError? = nil,
        stopError: AndroidEmulatorError? = nil,
        blockLaunch: Bool = false,
        blockStop: Bool = false
    ) {
        self.snapshots = snapshots
        self.launchError = launchError
        self.stopError = stopError
        self.blockLaunch = blockLaunch
        self.blockStop = blockStop
    }

    func snapshot() async throws -> AndroidEmulatorSnapshot {
        guard !snapshots.isEmpty else {
            return AndroidEmulatorSnapshot(
                sdkRootURL: URL(fileURLWithPath: "/sdk", isDirectory: true),
                devices: [],
                warning: nil,
                connectedEmulatorSerials: []
            )
        }
        return try snapshots.removeFirst().get()
    }

    func launch(avdName: String) async throws {
        _ = avdName
        if let launchError { throw launchError }
        launchStarted = true
        launchStartContinuation?.resume()
        launchStartContinuation = nil
        if blockLaunch {
            await withCheckedContinuation { launchReleaseContinuation = $0 }
        }
    }

    func stop(serial: String) async throws {
        _ = serial
        if let stopError { throw stopError }
        stopStarted = true
        stopStartContinuation?.resume()
        stopStartContinuation = nil
        if blockStop {
            await withCheckedContinuation { stopReleaseContinuation = $0 }
        }
    }

    func waitUntilLaunchStarted() async {
        if launchStarted { return }
        await withCheckedContinuation { launchStartContinuation = $0 }
    }

    func waitUntilStopStarted() async {
        if stopStarted { return }
        await withCheckedContinuation { stopStartContinuation = $0 }
    }

    func releaseLaunch() {
        launchReleaseContinuation?.resume()
        launchReleaseContinuation = nil
    }

    func releaseStop() {
        stopReleaseContinuation?.resume()
        stopReleaseContinuation = nil
    }
}
