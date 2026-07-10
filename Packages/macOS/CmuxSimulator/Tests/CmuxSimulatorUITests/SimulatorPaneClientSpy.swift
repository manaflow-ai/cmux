import CmuxSimulator
@testable import CmuxSimulatorUI

actor SimulatorPaneClientSpy: SimulatorPaneClient {
    typealias Activation = SimulatorPaneClientActivation

    nonisolated let contextCache = SimulatorRemoteContextCache()
    private let devicesValue: [SimulatorDevice]
    private let applicationValues: [SimulatorInstalledApplication]
    private let delaysApplicationList: Bool
    private let eventStream: SimulatorWorkerEventStream
    private let eventContinuation: SimulatorWorkerEventStream.Continuation
    private var sentMessages: [SimulatorWorkerInbound] = []
    private var activationValues: [Activation] = []
    private var stopValue = 0
    private var invalidationValue = 0
    private var actionValues: [SimulatorControlAction] = []
    private var delayedApplicationList: CheckedContinuation<SimulatorControlResult, Never>?

    init(
        devices: [SimulatorDevice],
        applications: [SimulatorInstalledApplication] = [],
        delaysApplicationList: Bool = false
    ) {
        self.devicesValue = devices
        self.applicationValues = applications
        self.delaysApplicationList = delaysApplicationList
        let (stream, continuation) = SimulatorWorkerEventStream.makeStream(
            maximumBufferedBytes: 1_024 * 1_024,
            maximumBufferedEvents: 64,
            onTermination: {}
        )
        self.eventStream = stream
        self.eventContinuation = continuation
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        devicesValue
    }

    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {
        activationValues.append(Activation(id: id, geometry: geometry))
    }

    func shutdownDevice(id: String) async throws {}

    func subscribe() async -> SimulatorWorkerEventStream {
        eventStream
    }

    func send(_ message: SimulatorWorkerInbound) async {
        sentMessages.append(message)
    }

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        actionValues.append(action)
        if case .listApplications = action {
            if delaysApplicationList {
                return await withCheckedContinuation { delayedApplicationList = $0 }
            }
            return .applications(applicationValues)
        }
        return .none
    }

    func invalidateWorker() async { invalidationValue += 1 }

    func stop() async { stopValue += 1 }

    func emit(_ event: SimulatorWorkerEvent) {
        _ = eventContinuation.yield(event)
    }

    func messages() -> [SimulatorWorkerInbound] {
        sentMessages
    }

    func activations() -> [Activation] {
        activationValues
    }

    func stopCount() -> Int {
        stopValue
    }

    func invalidationCount() -> Int {
        invalidationValue
    }

    func actions() -> [SimulatorControlAction] {
        actionValues
    }

    func hasDelayedApplicationList() -> Bool {
        delayedApplicationList != nil
    }

    func resumeApplicationList(with applications: [SimulatorInstalledApplication]) {
        delayedApplicationList?.resume(returning: .applications(applications))
        delayedApplicationList = nil
    }
}
