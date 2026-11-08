import CmuxSimulator
@testable import CmuxSimulatorUI

actor LiveStatusPaneClient: SimulatorPaneClient {
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
        let source = SimulatorWorkerEventStreamSource(
            maximumBufferedBytes: 1_024 * 1_024,
            maximumBufferedEvents: 64,
            onTermination: {}
        )
        stream = source.stream
        continuation = source.continuation
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
    func synchronizeOrientation(
        _ orientation: SimulatorOrientation
    ) async throws -> SimulatorDisplayMetadata? { nil }
    func invalidateWorker() async {}
    func stop() async { stops += 1; await continuation.finish() }

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

    func emit(_ event: SimulatorWorkerEvent) async { _ = await continuation.yield(event) }
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
