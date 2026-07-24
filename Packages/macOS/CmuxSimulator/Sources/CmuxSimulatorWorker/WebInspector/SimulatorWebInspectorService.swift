import CmuxSimulator
import Foundation

@MainActor
final class SimulatorWebInspectorService {
    typealias Event = SimulatorWebInspectorEvent
    typealias Session = SimulatorWebInspectorSession

    typealias RefreshContinuation = CheckedContinuation<[SimulatorWebInspectorTarget], Error>

    var eventHandler: ((Event) -> Void)?

    let discovery: SimulatorWebInspectorSocketDiscovery
    let frameCodec: SimulatorWebInspectorPlistFrameCodec
    let socketConnector: SimulatorWebInspectorSocketConnector
    let sleeper: any SimulatorWebInspectorSleeping
    let mutationGate: SimulatorMutationGate
    var socket: (any SimulatorWebInspectorTransport)?
    var socketReaderTask: Task<Void, Never>?
    var currentDeviceIdentifier: String?
    var connectionIdentifier = UUID().uuidString
    var catalog = SimulatorWebInspectorTargetCatalog()
    var targetPublicationTask: Task<Void, Never>?
    var targetPublicationGeneration: UInt64 = 0
    var lastPublishedTargets: [SimulatorWebInspectorTarget] = []
    var subscribedApplicationIdentifiers: Set<String> = []
    var pendingListingIdentifiers: Set<String> = []
    var refreshContinuation: RefreshContinuation?
    var refreshTimeoutTask: Task<Void, Never>?
    var lastRefreshWasAuthoritative = false
    var refreshCensusPending = false
    var session: Session?
    var sessionLease: SimulatorMutationLease?
    var nextInternalRequestIdentifier: Int64 = -9_000_000_000_000_000
    static let firstReservedInternalRequestIdentifier: Int64 = -9_000_000_000_000_000
    var pendingInternalRequests: [Int64: CheckedContinuation<Data, Error>] = [:]
    var internalRequestTimeoutTasks: [Int64: Task<Void, Never>] = [:]
    var routingContinuation: CheckedContinuation<Void, Error>?
    var routingTimeoutTask: Task<Void, Never>?

    init(
        subprocessRunner: SimulatorSubprocessRunner,
        sleeper: any SimulatorWebInspectorSleeping = ContinuousSimulatorWebInspectorSleeper(),
        mutationGate: SimulatorMutationGate = SimulatorMutationGate(),
        frameCodec: SimulatorWebInspectorPlistFrameCodec = SimulatorWebInspectorPlistFrameCodec(),
        socketConnector: SimulatorWebInspectorSocketConnector? = nil
    ) {
        discovery = SimulatorWebInspectorSocketDiscovery(subprocessRunner: subprocessRunner)
        self.frameCodec = frameCodec
        self.socketConnector = socketConnector
            ?? SimulatorWebInspectorSocketConnector(frameCodec: frameCodec)
        self.sleeper = sleeper
        self.mutationGate = mutationGate
    }

    func isAvailable(deviceIdentifier: String) async -> Bool {
        (try? await discovery.socketPath(deviceIdentifier: deviceIdentifier)) != nil
    }

    func refreshTargets(deviceIdentifier: String) async throws -> [SimulatorWebInspectorTarget] {
        try await ensureConnected(deviceIdentifier: deviceIdentifier)
        cancelRefresh(with: SimulatorWebInspectorError.unavailable(
            "A newer Web Inspector target refresh replaced this request."
        ))
        subscribedApplicationIdentifiers.removeAll()
        pendingListingIdentifiers.removeAll()
        lastRefreshWasAuthoritative = false
        refreshCensusPending = true

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                refreshContinuation = continuation
                refreshTimeoutTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.sleeper.sleep(for: .seconds(5))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self.finishRefresh(authoritative: false)
                }
                do {
                    try sendRPC(selector: "_rpc_reportIdentifier:")
                    try sendRPC(selector: "_rpc_getConnectedApplications:")
                } catch {
                    cancelRefresh(with: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRefresh(with: CancellationError())
            }
        }
    }

    func attach(targetIdentifier: String) async throws -> SimulatorWebInspectorSessionStatus {
        guard socket != nil,
              let deviceIdentifier = currentDeviceIdentifier,
              let target = catalog.target(id: targetIdentifier) else {
            throw SimulatorWebInspectorError.targetNotFound
        }
        if session != nil { try await releaseSession(emit: false) }
        let key = try mutationKey(deviceIdentifier: deviceIdentifier, target: target)
        let lease = try await mutationGate.acquireLocks([key])
        let refreshedTargets: [SimulatorWebInspectorTarget]
        do {
            refreshedTargets = try await refreshTargets(deviceIdentifier: deviceIdentifier)
        } catch {
            lease.release()
            throw error
        }
        guard lastRefreshWasAuthoritative else {
            lease.release()
            throw SimulatorWebInspectorError.timedOut("target occupancy refresh")
        }
        guard let currentTarget = refreshedTargets.first(where: { $0.id == targetIdentifier }) else {
            lease.release()
            throw SimulatorWebInspectorError.targetNotFound
        }
        guard !currentTarget.isInUse else {
            lease.release()
            throw SimulatorWebInspectorError.targetInUse
        }
        let identifier = UUID()
        let senderIdentifier = UUID().uuidString
        sessionLease = lease
        session = Session(
            identifier: identifier,
            target: currentTarget,
            senderIdentifier: senderIdentifier
        )
        do {
            try sendRPC(selector: "_rpc_forwardSocketSetup:", arguments: [
                "WIRApplicationIdentifierKey": currentTarget.applicationIdentifier,
                "WIRPageIdentifierKey": NSNumber(value: currentTarget.pageIdentifier),
                "WIRSenderKey": senderIdentifier,
                "WIRAutomaticallyPause": false,
            ])
            try await negotiateSessionRouting()
        } catch {
            releaseSessionWithoutMutationGate(emit: false)
            throw error
        }
        let status = SimulatorWebInspectorSessionStatus.attached(
            sessionID: identifier,
            targetID: currentTarget.id
        )
        eventHandler?(.session(status))
        return status
    }

    func releaseSession(emit: Bool = true) async throws {
        guard let session else {
            sessionLease?.release()
            sessionLease = nil
            if emit { eventHandler?(.session(.detached)) }
            return
        }
        if sessionLease == nil {
            guard let deviceIdentifier = currentDeviceIdentifier else {
                throw SimulatorWebInspectorError.sessionUnavailable
            }
            let key = try mutationKey(deviceIdentifier: deviceIdentifier, target: session.target)
            let transientLease = try await mutationGate.acquireLocks([key])
            defer { transientLease.release() }
            guard self.session?.identifier == session.identifier else { return }
            releaseSessionWithoutMutationGate(emit: emit)
            return
        }
        guard self.session?.identifier == session.identifier else { return }
        releaseSessionWithoutMutationGate(emit: emit)
    }

    func releaseSessionWithoutMutationGate(emit: Bool = true) {
        guard let session else {
            sessionLease?.release()
            sessionLease = nil
            if emit { eventHandler?(.session(.detached)) }
            return
        }
        self.session = nil
        failRoutingNegotiation(with: SimulatorWebInspectorError.sessionUnavailable)
        failInternalRequests(with: SimulatorWebInspectorError.sessionUnavailable)
        try? sendRPC(selector: "_rpc_forwardDidClose:", arguments: [
            "WIRApplicationIdentifierKey": session.target.applicationIdentifier,
            "WIRPageIdentifierKey": NSNumber(value: session.target.pageIdentifier),
            "WIRSenderKey": session.senderIdentifier,
        ])
        sessionLease?.release()
        sessionLease = nil
        if emit { eventHandler?(.session(.detached)) }
    }

    func releaseSession(ifOwnedBy bundleIdentifier: String) async throws {
        guard session?.target.bundleIdentifier == bundleIdentifier else { return }
        try await releaseSession()
    }

    func releaseSessionWithoutMutationGate(ifOwnedBy bundleIdentifier: String) {
        guard session?.target.bundleIdentifier == bundleIdentifier else { return }
        releaseSessionWithoutMutationGate()
    }

    func sendMessage(_ rawJSON: String) async throws {
        guard let session, sessionLease != nil else {
            throw SimulatorWebInspectorError.sessionUnavailable
        }
        guard self.session?.identifier == session.identifier else {
            throw SimulatorWebInspectorError.sessionUnavailable
        }
        try sendMessageWithoutMutationGate(rawJSON)
    }

    func sendMessageWithoutMutationGate(
        _ rawJSON: String,
        allowingReservedInternalIdentifier: Bool = false
    ) throws {
        guard var session else { throw SimulatorWebInspectorError.sessionUnavailable }
        let payload = Data(rawJSON.utf8)
        if !allowingReservedInternalIdentifier,
           let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let identifier = simulatorWebInspectorInteger(object["id"]),
           identifier <= Self.firstReservedInternalRequestIdentifier {
            throw SimulatorWebInspectorError.reservedIdentifier
        }
        let outgoing = try session.router.routeOutgoing(payload)
        self.session = session
        for message in outgoing { try sendToTarget(message) }
    }

    func setHighlight(enabled: Bool) async throws {
        guard let session, sessionLease != nil else {
            throw SimulatorWebInspectorError.sessionUnavailable
        }
        guard self.session?.identifier == session.identifier else {
            throw SimulatorWebInspectorError.sessionUnavailable
        }
        try await setHighlightWithoutMutationGate(enabled: enabled)
    }

    private func setHighlightWithoutMutationGate(enabled: Bool) async throws {
        if enabled {
            let document = try await callTarget(method: "DOM.getDocument", parameters: ["depth": 0])
            guard let result = document["result"] as? [String: Any],
                  let root = result["root"] as? [String: Any],
                  let nodeIdentifier = simulatorWebInspectorInteger(root["nodeId"]) else {
                throw SimulatorWebInspectorError.invalidMessage
            }
            _ = try await callTarget(method: "DOM.highlightNode", parameters: [
                "nodeId": nodeIdentifier,
                "highlightConfig": [
                    "showInfo": false,
                    "contentColor": ["r": 111, "g": 168, "b": 220, "a": 0.55],
                    "paddingColor": ["r": 147, "g": 196, "b": 125, "a": 0],
                    "borderColor": ["r": 255, "g": 229, "b": 153, "a": 0],
                    "marginColor": ["r": 246, "g": 178, "b": 107, "a": 0],
                ],
            ])
        } else {
            _ = try await callTarget(method: "DOM.hideHighlight")
        }
    }

    func shutdown() {
        cancelRefresh(with: SimulatorWebInspectorError.transportClosed)
        releaseSessionWithoutMutationGate(emit: false)
        socketReaderTask?.cancel()
        socketReaderTask = nil
        socket?.close()
        socket = nil
        currentDeviceIdentifier = nil
        targetPublicationGeneration &+= 1
        targetPublicationTask?.cancel()
        targetPublicationTask = nil
        lastPublishedTargets = []
        catalog.reset()
        subscribedApplicationIdentifiers.removeAll()
        pendingListingIdentifiers.removeAll()
    }

    private func ensureConnected(deviceIdentifier: String) async throws {
        if socket != nil, currentDeviceIdentifier == deviceIdentifier { return }
        try? await releaseSession(emit: false)
        shutdown()
        let path = try await discovery.socketPath(deviceIdentifier: deviceIdentifier)
        let socket = try socketConnector.connect(path: path)
        self.socket = socket
        currentDeviceIdentifier = deviceIdentifier
        connectionIdentifier = UUID().uuidString
        let messages = socket.messages
        socketReaderTask = Task { @MainActor [weak self, weak socket] in
            for await data in messages {
                guard !Task.isCancelled, let self, let socket, self.socket === socket else {
                    return
                }
                self.receive(propertyListBody: data)
            }
            guard !Task.isCancelled, let self, let socket, self.socket === socket else { return }
            self.transportEnded()
        }
    }

    func sendRPC(selector: String, arguments: [String: Any] = [:]) throws {
        guard let socket else { throw SimulatorWebInspectorError.transportClosed }
        var argument = arguments
        argument["WIRConnectionIdentifierKey"] = connectionIdentifier
        do {
            try socket.send(propertyList: [
                "__selector": selector,
                "__argument": argument,
            ])
        } catch {
            transportEnded(error: error)
            throw error
        }
    }

    func finishRefresh(authoritative: Bool) {
        guard let continuation = refreshContinuation else { return }
        lastRefreshWasAuthoritative = authoritative
        refreshCensusPending = false
        refreshContinuation = nil
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = nil
        continuation.resume(returning: catalog.targets)
    }

    func cancelRefresh(with error: Error) {
        let continuation = refreshContinuation
        refreshContinuation = nil
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = nil
        lastRefreshWasAuthoritative = false
        refreshCensusPending = false
        continuation?.resume(throwing: error)
    }

    private func mutationKey(
        deviceIdentifier: String,
        target: SimulatorWebInspectorTarget
    ) throws -> SimulatorMutationKey {
        guard let bundleIdentifier = target.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            throw SimulatorWebInspectorError.unavailable(
                "Web Inspector did not report the target application's bundle identifier."
            )
        }
        return .webInspector(
            deviceIdentifier: deviceIdentifier,
            name: "\(bundleIdentifier)|\(target.id)"
        )
    }
}

func simulatorWebInspectorInteger(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    return nil
}
