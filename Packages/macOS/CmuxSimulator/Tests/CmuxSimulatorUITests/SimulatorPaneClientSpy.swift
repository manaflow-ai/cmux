import CmuxSimulator
@testable import CmuxSimulatorUI

actor SimulatorPaneClientSpy: SimulatorPaneClient {
    typealias Activation = SimulatorPaneClientActivation

    private var devicesValue: [SimulatorDevice]
    private let applicationValues: [SimulatorInstalledApplication]
    private let delaysApplicationList: Bool
    private let delaysInvalidation: Bool
    private let delaysActivation: Bool
    private let delaysWebInspectorSend: Bool
    private let failsApplicationInstall: Bool
    private let failsCameraDisable: Bool
    private let failsWebInspectorHighlight: Bool
    private let failsWebInspectorRelease: Bool
    private let cancelsControlActionBeforeReturning: Bool
    private let eventStream: SimulatorWorkerEventStream
    private let eventContinuation: SimulatorWorkerEventStream.Continuation
    private var sentMessages: [SimulatorWorkerInbound] = []
    private var activationValues: [Activation] = []
    private var stopValue = 0
    private var invalidationValue = 0
    private var actionValues: [SimulatorControlAction] = []
    private var delayedApplicationList: CheckedContinuation<SimulatorControlResult, Never>?
    private var delayedInvalidation: CheckedContinuation<Void, Never>?
    private var delayedActivation: CheckedContinuation<Void, Error>?
    private var activationCancellationValue = 0
    private var delayedWebInspectorSend: CheckedContinuation<SimulatorControlResult, Error>?
    private var webInspectorSendCancellationValue = 0

    init(
        devices: [SimulatorDevice],
        applications: [SimulatorInstalledApplication] = [],
        delaysApplicationList: Bool = false,
        delaysInvalidation: Bool = false,
        delaysActivation: Bool = false,
        delaysWebInspectorSend: Bool = false,
        failsApplicationInstall: Bool = false,
        failsCameraDisable: Bool = false,
        failsWebInspectorHighlight: Bool = false,
        failsWebInspectorRelease: Bool = false,
        cancelsControlActionBeforeReturning: Bool = false
    ) {
        self.devicesValue = devices
        self.applicationValues = applications
        self.delaysApplicationList = delaysApplicationList
        self.delaysInvalidation = delaysInvalidation
        self.delaysActivation = delaysActivation
        self.delaysWebInspectorSend = delaysWebInspectorSend
        self.failsApplicationInstall = failsApplicationInstall
        self.failsCameraDisable = failsCameraDisable
        self.failsWebInspectorHighlight = failsWebInspectorHighlight
        self.failsWebInspectorRelease = failsWebInspectorRelease
        self.cancelsControlActionBeforeReturning = cancelsControlActionBeforeReturning
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

    func setDevices(_ devices: [SimulatorDevice]) {
        devicesValue = devices
    }

    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {
        activationValues.append(Activation(id: id, geometry: geometry))
        guard delaysActivation else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    delayedActivation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelDelayedActivation() }
        }
    }

    func shutdownDevice(id: String) async throws {}

    func subscribe() async -> SimulatorWorkerEventStream {
        eventStream
    }

    func send(_ message: SimulatorWorkerInbound) async {
        sentMessages.append(message)
    }

    func synchronizeOrientation(
        _ orientation: SimulatorOrientation
    ) async throws -> SimulatorDisplayMetadata? {
        sentMessages.append(.rotate(orientation))
        return nil
    }

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        actionValues.append(action)
        if cancelsControlActionBeforeReturning {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if case .sendWebInspectorMessage = action, delaysWebInspectorSend {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        delayedWebInspectorSend = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelDelayedWebInspectorSend() }
            }
        }
        if case .installApplication = action, failsApplicationInstall {
            throw SimulatorFailure(
                code: "fixture_install_failed",
                message: "The fixture app is invalid.",
                isRecoverable: true
            )
        }
        if case .configureCamera(.disabled) = action, failsCameraDisable {
            throw SimulatorFailure(
                code: "fixture_camera_cleanup_failed",
                message: "The fixture camera could not be disabled.",
                isRecoverable: true
            )
        }
        if case .setWebInspectorHighlight = action, failsWebInspectorHighlight {
            throw SimulatorFailure(
                code: "fixture_highlight_failed",
                message: "The target rejected highlight cleanup.",
                isRecoverable: true
            )
        }
        if case .releaseWebInspector = action, failsWebInspectorRelease {
            throw SimulatorFailure(
                code: "fixture_release_failed",
                message: "The target rejected Inspector release.",
                isRecoverable: true
            )
        }
        if case .releaseWebInspector = action {
            return .webInspectorSession(.detached)
        }
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

    func activationCancellationCount() -> Int {
        activationCancellationValue
    }

    func hasDelayedActivation() -> Bool {
        delayedActivation != nil
    }

    func resumeActivation() {
        delayedActivation?.resume()
        delayedActivation = nil
    }

    private func cancelDelayedActivation() {
        activationCancellationValue += 1
        delayedActivation?.resume(throwing: CancellationError())
        delayedActivation = nil
    }

    func hasDelayedWebInspectorSend() -> Bool {
        delayedWebInspectorSend != nil
    }

    func webInspectorSendCancellationCount() -> Int {
        webInspectorSendCancellationValue
    }

    private func cancelDelayedWebInspectorSend() {
        webInspectorSendCancellationValue += 1
        delayedWebInspectorSend?.resume(throwing: CancellationError())
        delayedWebInspectorSend = nil
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
