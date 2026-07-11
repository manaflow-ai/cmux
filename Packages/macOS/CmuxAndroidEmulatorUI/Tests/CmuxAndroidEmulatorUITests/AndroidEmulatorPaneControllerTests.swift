@testable import CmuxAndroidEmulatorUI
import CmuxAndroidEmulator
import Foundation
import Testing

@Suite
struct AndroidEmulatorPaneControllerTests {
    @MainActor
    @Test
    func serializesRapidControlActions() async {
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
        await service.releaseFirstControl()
        await service.waitUntilControlCount(2)

        #expect(await service.recordedControls == [.rotateRight, .rotateRight])
        #expect(await service.maximumConcurrentControls == 1)
    }
}

private actor SerializingControlService: AndroidEmulatorServicing {
    private var controls: [AndroidEmulatorControlAction] = []
    private var activeControlCount = 0
    private var maximumActiveControlCount = 0
    private var firstControlStarted: CheckedContinuation<Void, Never>?
    private var firstControlRelease: CheckedContinuation<Void, Never>?
    private var controlCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var recordedControls: [AndroidEmulatorControlAction] { controls }
    var maximumConcurrentControls: Int { maximumActiveControlCount }

    func snapshot() async throws -> AndroidEmulatorSnapshot {
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
        notifyControlCountWaiters()
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

    func waitUntilControlCount(_ count: Int) async {
        guard controls.count < count else { return }
        await withCheckedContinuation { continuation in
            controlCountWaiters.append((count, continuation))
        }
    }

    private func notifyControlCountWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in controlCountWaiters {
            if controls.count >= count {
                continuation.resume()
            } else {
                pending.append((count, continuation))
            }
        }
        controlCountWaiters = pending
    }

    private enum TestError: Error {
        case unused
    }
}
