import CmuxSimulator
@testable import CmuxSimulatorUI

actor LocationLifecyclePaneClient: SimulatorPaneClient {
    private var deviceValues: [SimulatorDevice]
    private let stream: SimulatorWorkerEventStream
    private let continuation: SimulatorWorkerEventStream.Continuation
    private var operationValues: [String] = []
    private var discoveryFailure: SimulatorFailure?

    init(devices: [SimulatorDevice]) {
        deviceValues = devices
        let source = SimulatorWorkerEventStreamSource(
            maximumBufferedBytes: 4_096,
            maximumBufferedEvents: 32,
            onTermination: {}
        )
        self.stream = source.stream
        self.continuation = source.continuation
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        if let discoveryFailure { throw discoveryFailure }
        return deviceValues
    }

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
        await continuation.finish()
    }

    func emit(_ event: SimulatorWorkerEvent) async {
        _ = await continuation.yield(event)
    }

    func setDevices(_ devices: [SimulatorDevice]) { deviceValues = devices }
    func setDiscoveryFailure(_ failure: SimulatorFailure?) { discoveryFailure = failure }
    func operations() -> [String] { operationValues }
}
