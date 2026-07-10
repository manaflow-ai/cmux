import CmuxSimulator
import Foundation

@MainActor
final class SimulatorWebInspectorService {
    enum Event {
        case targets([SimulatorWebInspectorTarget])
        case session(SimulatorWebInspectorSessionStatus)
        case message(SimulatorWebInspectorMessageChunk)
        case failure(SimulatorWebInspectorError)
    }

    struct Session {
        let identifier: UUID
        let target: SimulatorWebInspectorTarget
        let senderIdentifier: String
        var router = SimulatorWebInspectorSessionRouter()
    }

    typealias RefreshContinuation = CheckedContinuation<[SimulatorWebInspectorTarget], Error>

    var eventHandler: ((Event) -> Void)?

    let discovery: SimulatorWebInspectorSocketDiscovery
    let sleeper: any SimulatorWebInspectorSleeping
    var socket: (any SimulatorWebInspectorTransport)?
    var socketReaderTask: Task<Void, Never>?
    var currentDeviceIdentifier: String?
    var connectionIdentifier = UUID().uuidString
    var catalog = SimulatorWebInspectorTargetCatalog()
    var subscribedApplicationIdentifiers: Set<String> = []
    var pendingListingIdentifiers: Set<String> = []
    var refreshContinuation: RefreshContinuation?
    var refreshTimeoutTask: Task<Void, Never>?
    var session: Session?
    var nextInternalRequestIdentifier: Int64 = -9_000_000_000_000_000
    var pendingInternalRequests: [Int64: CheckedContinuation<Data, Error>] = [:]
    var internalRequestTimeoutTasks: [Int64: Task<Void, Never>] = [:]
    var routingContinuation: CheckedContinuation<Void, Error>?
    var routingTimeoutTask: Task<Void, Never>?

    init(
        subprocessRunner: SimulatorSubprocessRunner,
        sleeper: any SimulatorWebInspectorSleeping = ContinuousSimulatorWebInspectorSleeper()
    ) {
        discovery = SimulatorWebInspectorSocketDiscovery(subprocessRunner: subprocessRunner)
        self.sleeper = sleeper
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
                    self.finishRefresh()
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
        guard socket != nil, let target = catalog.target(id: targetIdentifier) else {
            throw SimulatorWebInspectorError.targetNotFound
        }
        guard !target.isInUse else { throw SimulatorWebInspectorError.targetInUse }
        releaseSession(emit: false)

        let identifier = UUID()
        let senderIdentifier = UUID().uuidString
        session = Session(
            identifier: identifier,
            target: target,
            senderIdentifier: senderIdentifier
        )
        do {
            try sendRPC(selector: "_rpc_forwardSocketSetup:", arguments: [
                "WIRApplicationIdentifierKey": target.applicationIdentifier,
                "WIRPageIdentifierKey": NSNumber(value: target.pageIdentifier),
                "WIRSenderKey": senderIdentifier,
                "WIRAutomaticallyPause": false,
            ])
            try await negotiateSessionRouting()
        } catch {
            releaseSession(emit: false)
            throw error
        }
        let status = SimulatorWebInspectorSessionStatus.attached(
            sessionID: identifier,
            targetID: target.id
        )
        eventHandler?(.session(status))
        return status
    }

    func releaseSession(emit: Bool = true) {
        guard let session else {
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
        if emit { eventHandler?(.session(.detached)) }
    }

    func sendMessage(_ rawJSON: String) throws {
        guard var session else { throw SimulatorWebInspectorError.sessionUnavailable }
        let payload = Data(rawJSON.utf8)
        let outgoing = try session.router.routeOutgoing(payload)
        self.session = session
        for message in outgoing { try sendToTarget(message) }
    }

    func setHighlight(enabled: Bool) async throws {
        if enabled {
            let document = try await callTarget(method: "DOM.getDocument", parameters: ["depth": 0])
            guard let result = document["result"] as? [String: Any],
                  let root = result["root"] as? [String: Any],
                  let nodeIdentifier = Self.integer(root["nodeId"]) else {
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
        releaseSession(emit: false)
        socketReaderTask?.cancel()
        socketReaderTask = nil
        socket?.close()
        socket = nil
        currentDeviceIdentifier = nil
        catalog.reset()
        subscribedApplicationIdentifiers.removeAll()
        pendingListingIdentifiers.removeAll()
    }

    private func ensureConnected(deviceIdentifier: String) async throws {
        if socket != nil, currentDeviceIdentifier == deviceIdentifier { return }
        shutdown()
        let path = try await discovery.socketPath(deviceIdentifier: deviceIdentifier)
        let socket = try SimulatorWebInspectorSocket.connect(path: path)
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

    func finishRefresh() {
        guard let continuation = refreshContinuation else { return }
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
        continuation?.resume(throwing: error)
    }

    static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return nil
    }
}
