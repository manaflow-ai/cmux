import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@MainActor
@Suite("Simulator live status watcher")
struct SimulatorLiveStatusWatcherTests {
    @Test("Visible panes refresh distinct foreground and camera state without overlap")
    func visibilityAndWorkerLifecycle() async {
        let client = LiveStatusPaneClient()
        let sleeper = LiveStatusSleepGate()
        let coordinator = SimulatorPaneCoordinator(
            client: client,
            webInspectorSleeper: sleeper
        )
        coordinator.setLiveStatusVisibility(false)
        await coordinator.start()
        await client.emit(.message(.capabilities([.foregroundApplication, .cameraInjection])))
        await client.emit(.message(.status(.streaming)))
        await eventually { coordinator.status == .streaming }
        #expect(await client.readCounts() == (0, 0))

        coordinator.setLiveStatusVisibility(true)
        await eventually {
            await client.readCounts() == (1, 1)
                && coordinator.foregroundApplication?.bundleIdentifier == "com.example.first"
                && coordinator.cameraStatus?.targetIsAttached == false
        }
        await sleeper.waitForStarts(1)

        await client.setSecondSnapshot()
        await sleeper.advance()
        await eventually {
            await client.readCounts() == (2, 2)
                && coordinator.foregroundApplication?.bundleIdentifier == "com.example.second"
                && coordinator.foregroundApplication?.processIdentifier == 202
                && coordinator.cameraStatus?.targetIsAttached == true
        }

        await client.setCameraFailure(true)
        await sleeper.advance()
        await eventually { await client.readCounts() == (3, 3) }
        await sleeper.waitForStarts(3)
        #expect(await sleeper.recordedDurations().last == .seconds(5))

        coordinator.setLiveStatusVisibility(false)
        await sleeper.waitForCancellations(1)
        let hiddenCounts = await client.readCounts()
        await Task.yield()
        #expect(await client.readCounts() == hiddenCounts)

        coordinator.setLiveStatusVisibility(true)
        await eventually { await client.readCounts().0 == hiddenCounts.0 + 1 }
        await sleeper.waitForStarts(4)
        await client.emit(.workerStopped)
        await sleeper.waitForCancellations(2)
        let crashedCounts = await client.readCounts()
        await Task.yield()

        #expect(await client.readCounts() == crashedCounts)
        #expect(await client.maximumConcurrentReads() == 1)
        await coordinator.close()
        #expect(await client.stopCount() == 1)
    }

    private func eventually(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }
}

private actor LiveStatusPaneClient: SimulatorPaneClient {
    nonisolated let contextCache = SimulatorRemoteContextCache()
    private let stream: SimulatorWorkerEventStream
    private let continuation: SimulatorWorkerEventStream.Continuation
    private var foreground = LiveStatusPaneClient.application(
        bundle: "com.example.first",
        pid: 101
    )
    private var camera = LiveStatusPaneClient.camera(attached: false)
    private var foregroundReads = 0
    private var cameraReads = 0
    private var concurrentReads = 0
    private var maximumReads = 0
    private var stops = 0
    private var cameraFailure = false

    init() {
        (stream, continuation) = SimulatorWorkerEventStream.makeStream(
            maximumBufferedBytes: 1_024 * 1_024,
            maximumBufferedEvents: 64,
            onTermination: {}
        )
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        [SimulatorDevice(
            id: "DEVICE", name: "iPhone", runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5", deviceTypeIdentifier: "phone",
            family: .iPhone, state: .booted, isAvailable: true, lastBootedAt: nil
        )]
    }

    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {}
    func shutdownDevice(id: String) async throws {}
    func subscribe() async -> SimulatorWorkerEventStream { stream }
    func send(_ message: SimulatorWorkerInbound) async {}
    func invalidateWorker() async {}
    func stop() async { stops += 1; continuation.finish() }

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        concurrentReads += 1
        maximumReads = max(maximumReads, concurrentReads)
        defer { concurrentReads -= 1 }
        switch action {
        case .readForegroundApplication:
            foregroundReads += 1
            return .foregroundApplication(foreground)
        case .readCameraStatus:
            cameraReads += 1
            if cameraFailure {
                throw SimulatorFailure(
                    code: "camera_status_failed",
                    message: "Unavailable",
                    isRecoverable: true
                )
            }
            return .cameraStatus(camera)
        default:
            return .none
        }
    }

    func emit(_ event: SimulatorWorkerEvent) { _ = continuation.yield(event) }
    func readCounts() -> (Int, Int) { (foregroundReads, cameraReads) }
    func maximumConcurrentReads() -> Int { maximumReads }
    func stopCount() -> Int { stops }

    func setSecondSnapshot() {
        foreground = Self.application(bundle: "com.example.second", pid: 202)
        camera = Self.camera(attached: true)
    }

    func setCameraFailure(_ fails: Bool) { cameraFailure = fails }

    private static func application(bundle: String, pid: Int32) -> SimulatorApplicationInfo {
        SimulatorApplicationInfo(
            bundleIdentifier: bundle, processIdentifier: pid, name: nil,
            version: nil, build: nil, minimumOSVersion: nil, isReactNative: false
        )
    }

    private static func camera(attached: Bool) -> SimulatorCameraStatus {
        SimulatorCameraStatus(
            configuration: .placeholder, mirrorMode: .auto,
            injectedBundleIdentifiers: attached ? ["com.example.second"] : [],
            targetBundleIdentifier: attached ? "com.example.second" : "com.example.first",
            targetProcessIdentifier: attached ? 202 : 101,
            targetIsAlive: attached, targetIsAttached: attached, hostCameras: []
        )
    }
}

private actor LiveStatusSleepGate: SimulatorProcessSleeper {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Waiter] = []
    private var starts = 0
    private var cancellations = 0
    private var durations: [Duration] = []
    private var startObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationObservers: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(for duration: Duration) async throws {
        _ = duration
        durations.append(duration)
        let id = UUID()
        starts += 1
        resumeObservers(&startObservers, count: starts)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advance() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func waitForStarts(_ expected: Int) async {
        guard starts < expected else { return }
        await withCheckedContinuation { startObservers.append((expected, $0)) }
    }

    func waitForCancellations(_ expected: Int) async {
        guard cancellations < expected else { return }
        await withCheckedContinuation { cancellationObservers.append((expected, $0)) }
    }

    func recordedDurations() -> [Duration] { durations }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        cancellations += 1
        resumeObservers(&cancellationObservers, count: cancellations)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeObservers(
        _ observers: inout [(Int, CheckedContinuation<Void, Never>)],
        count: Int
    ) {
        let ready = observers.filter { $0.0 <= count }
        observers.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
    }
}
