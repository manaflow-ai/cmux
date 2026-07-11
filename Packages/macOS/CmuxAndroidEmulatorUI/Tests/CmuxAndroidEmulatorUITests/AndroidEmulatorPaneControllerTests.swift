@testable import CmuxAndroidEmulatorUI
import CmuxAndroidEmulator
import Foundation
import Testing

@Suite
struct AndroidEmulatorPaneControllerTests {
    @MainActor
    @Test
    func boundsRapidControlActionsWhileOneIsRunning() async {
        let service = SerializingControlService()
        let controller = AndroidEmulatorPaneController(
            avdName: "Pixel_9_API_35",
            serial: "emulator-5554",
            transportID: "42",
            sdkRootURL: URL(fileURLWithPath: "/sdk"),
            coordinator: AndroidEmulatorCoordinator(service: service)
        )

        controller.perform(.rotateRight)
        controller.perform(.rotateRight)
        await service.waitUntilFirstControlStarts()

        #expect(controller.controlsBusy)
        #expect(await service.recordedControls == [.rotateRight])
        #expect(await service.maximumConcurrentControls == 1)
        await service.releaseFirstControl()
    }

    @MainActor
    @Test
    func successfulStopClearsAnExpectedCaptureDisconnectError() async {
        let service = SuccessfulStopService()
        let controller = AndroidEmulatorPaneController(
            avdName: "Pixel_9_API_35",
            serial: "emulator-5554",
            transportID: "42",
            sdkRootURL: URL(fileURLWithPath: "/sdk"),
            coordinator: AndroidEmulatorCoordinator(service: service)
        )
        let confirmation = StopConfirmation()
        controller.setStopConfirmedHandler { confirmation.confirm() }
        controller.reportCaptureError(TestCaptureError.disconnected)

        controller.stop()
        await confirmation.wait()

        #expect(controller.captureError == nil)
        #expect(controller.operationError == nil)
    }

    @MainActor
    @Test
    func retryRepeatsDisplayDiscoveryAfterTransientFailure() async {
        let service = RetryDisplaySizeService()
        let controller = AndroidEmulatorPaneController(
            avdName: "Pixel_9_API_35",
            serial: "emulator-5554",
            transportID: "42",
            sdkRootURL: URL(fileURLWithPath: "/sdk"),
            coordinator: AndroidEmulatorCoordinator(service: service)
        )

        await controller.prepare()
        #expect(!controller.isCaptureReady)
        #expect(controller.captureError != nil)

        let becameReady = Task { @MainActor in
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = controller.isCaptureReady
                } onChange: {
                    continuation.resume()
                }
            }
        }
        controller.retryCapture()
        await becameReady.value

        #expect(controller.isCaptureReady)
        #expect(controller.captureError == nil)
        #expect(await service.displaySizeRequestCount == 2)
    }
}

@MainActor
private final class StopConfirmation {
    private var continuation: CheckedContinuation<Void, Never>?
    private var confirmed = false

    func confirm() {
        confirmed = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        guard !confirmed else { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private enum TestCaptureError: LocalizedError {
    case disconnected

    var errorDescription: String? { "The file couldn’t be saved." }
}

private actor RetryDisplaySizeService: AndroidEmulatorServicing {
    private var requestCount = 0
    var displaySizeRequestCount: Int { requestCount }

    func snapshot() async throws -> AndroidEmulatorSnapshot { throw TestError.unused }
    func restartADB() async throws { throw TestError.unused }
    func launch(avdName: String) async throws { throw TestError.unused }
    func stop(avdName: String, serial: String, transportID: String) async throws { throw TestError.unused }
    func perform(
        _ action: AndroidEmulatorControlAction,
        avdName: String,
        serial: String,
        transportID: String
    ) async throws { throw TestError.unused }

    func displaySize(
        avdName: String,
        serial: String,
        transportID: String
    ) async throws -> AndroidEmulatorDisplaySize {
        requestCount += 1
        if requestCount == 1 { throw TestError.transient }
        return AndroidEmulatorDisplaySize(width: 1080, height: 1920)
    }

    private enum TestError: Error {
        case transient
        case unused
    }
}

private actor SuccessfulStopService: AndroidEmulatorServicing {
    func snapshot() async throws -> AndroidEmulatorSnapshot {
        AndroidEmulatorSnapshot(
            sdkRootURL: URL(fileURLWithPath: "/sdk"),
            devices: [AndroidVirtualDevice(name: "Pixel_9_API_35", state: .stopped)],
            warning: nil,
            connectedEmulatorSerials: []
        )
    }

    func launch(avdName: String) async throws {}
    func restartADB() async throws {}

    func stop(avdName: String, serial: String, transportID: String) async throws {}

    func perform(
        _ action: AndroidEmulatorControlAction,
        avdName: String,
        serial: String,
        transportID: String
    ) async throws {}

    func displaySize(
        avdName: String,
        serial: String,
        transportID: String
    ) async throws -> AndroidEmulatorDisplaySize {
        AndroidEmulatorDisplaySize(width: 1080, height: 1920)
    }
}

private actor SerializingControlService: AndroidEmulatorServicing {
    private var controls: [AndroidEmulatorControlAction] = []
    private var activeControlCount = 0
    private var maximumActiveControlCount = 0
    private var firstControlStarted: CheckedContinuation<Void, Never>?
    private var firstControlRelease: CheckedContinuation<Void, Never>?

    var recordedControls: [AndroidEmulatorControlAction] { controls }
    var maximumConcurrentControls: Int { maximumActiveControlCount }

    func snapshot() async throws -> AndroidEmulatorSnapshot {
        throw TestError.unused
    }

    func restartADB() async throws {
        throw TestError.unused
    }

    func launch(avdName: String) async throws {
        throw TestError.unused
    }

    func stop(avdName: String, serial: String, transportID: String) async throws {
        throw TestError.unused
    }

    func perform(
        _ action: AndroidEmulatorControlAction,
        avdName: String,
        serial: String,
        transportID: String
    ) async throws {
        controls.append(action)
        activeControlCount += 1
        maximumActiveControlCount = max(maximumActiveControlCount, activeControlCount)
        firstControlStarted?.resume()
        firstControlStarted = nil
        if controls.count == 1 {
            await withCheckedContinuation { continuation in
                firstControlRelease = continuation
            }
        }
        activeControlCount -= 1
    }

    func displaySize(
        avdName: String,
        serial: String,
        transportID: String
    ) async throws -> AndroidEmulatorDisplaySize {
        AndroidEmulatorDisplaySize(width: 1080, height: 1920)
    }

    func waitUntilFirstControlStarts() async {
        guard controls.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstControlStarted = continuation
        }
    }

    func releaseFirstControl() {
        firstControlRelease?.resume()
        firstControlRelease = nil
    }

    private enum TestError: Error {
        case unused
    }
}
