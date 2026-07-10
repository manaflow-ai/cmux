import CmuxSimulator
@testable import CmuxSimulatorUI

actor SimulatorPaneClientSpy: SimulatorPaneClient {
    typealias Activation = SimulatorPaneClientActivation

    private let devicesValue: [SimulatorDevice]
    private let applicationValues: [SimulatorInstalledApplication]
    private let delaysApplicationList: Bool
    private let delaysInvalidation: Bool
    private let eventStream: SimulatorWorkerEventStream
    private let eventContinuation: SimulatorWorkerEventStream.Continuation
    private var sentMessages: [SimulatorWorkerInbound] = []
    private var activationValues: [Activation] = []
    private var stopValue = 0
    private var invalidationValue = 0
    private var actionValues: [SimulatorControlAction] = []
    private var delayedApplicationList: CheckedContinuation<SimulatorControlResult, Never>?
    private var delayedInvalidation: CheckedContinuation<Void, Never>?

    init(
        devices: [SimulatorDevice],
        applications: [SimulatorInstalledApplication] = [],
        delaysApplicationList: Bool = false,
        delaysInvalidation: Bool = false
    ) {
        self.devicesValue = devices
        self.applicationValues = applications
        self.delaysApplicationList = delaysApplicationList
        self.delaysInvalidation = delaysInvalidation
        let source = SimulatorWorkerEventStreamSource(
            maximumBufferedBytes: 1_024 * 1_024,
            maximumBufferedEvents: 64,
            onTermination: {}
        )
        self.eventStream = source.stream
        self.eventContinuation = source.continuation
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

    func invalidateWorker() async {
        invalidationValue += 1
        if delaysInvalidation {
            await withCheckedContinuation { delayedInvalidation = $0 }
        }
    }

    func stop() async { stopValue += 1 }

    func emit(_ event: SimulatorWorkerEvent) async {
        _ = await eventContinuation.yield(event)
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

    func hasDelayedInvalidation() -> Bool {
        delayedInvalidation != nil
    }

    func resumeInvalidation() {
        delayedInvalidation?.resume()
        delayedInvalidation = nil
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
