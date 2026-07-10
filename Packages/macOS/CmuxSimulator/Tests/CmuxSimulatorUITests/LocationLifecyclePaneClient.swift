import CmuxSimulator
@testable import CmuxSimulatorUI

actor LocationLifecyclePaneClient: SimulatorPaneClient {
    nonisolated let contextCache = SimulatorRemoteContextCache()
    private var deviceValues: [SimulatorDevice]
    private let stream: SimulatorWorkerEventStream
    private let continuation: SimulatorWorkerEventStream.Continuation
    private var operationValues: [String] = []

    init(devices: [SimulatorDevice]) {
        deviceValues = devices
        let (stream, continuation) = SimulatorWorkerEventStream.makeStream(
            maximumBufferedBytes: 4_096,
            maximumBufferedEvents: 32,
            onTermination: {}
        )
        self.stream = stream
        self.continuation = continuation
    }

    func discoverDevices() async throws -> [SimulatorDevice] { deviceValues }

    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {
        operationValues.append("activate:\(id)")
    }

    func shutdownDevice(id: String) async throws {
        operationValues.append("shutdown:\(id)")
    }

    func subscribe() async -> SimulatorWorkerEventStream { stream }
    func send(_ message: SimulatorWorkerInbound) async {}

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        switch action {
        case let .startLocationRoute(deviceID, _):
            operationValues.append("start:\(deviceID)")
        case let .stopLocationRoute(deviceID):
            operationValues.append("stop:\(deviceID)")
        default:
            break
        }
        return .none
    }

    func invalidateWorker() async {}

    func stop() async {
        operationValues.append("close")
        continuation.finish()
    }

    func emit(_ event: SimulatorWorkerEvent) {
        _ = continuation.yield(event)
    }

    func setDevices(_ devices: [SimulatorDevice]) { deviceValues = devices }
    func operations() -> [String] { operationValues }
}
