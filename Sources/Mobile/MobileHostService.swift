import CMUXMobileCore
import Foundation
@preconcurrency import Network
import OSLog

private let mobileHostLog = Logger(subsystem: "dev.cmux", category: "mobile-host")

struct MobileHostServiceStatus {
    let isRunning: Bool
    let port: Int?
    let routes: [CmxAttachRoute]
    let activeConnectionCount: Int
    let lastErrorDescription: String?

    var payload: [String: Any] {
        [
            "is_running": isRunning,
            "port": port ?? NSNull(),
            "routes": routes.map(\.mobileHostJSONObject),
            "active_connection_count": activeConnectionCount,
            "last_error": lastErrorDescription ?? NSNull()
        ]
    }
}

@MainActor
final class MobileHostService {
    static let shared = MobileHostService()
    static let preferredPort = 4865

    private let callbackQueue = DispatchQueue(label: "dev.cmux.mobile.host-listener")
    private let routeResolver = MobileRouteResolver()
    private let ticketStore = MobileAttachTicketStore()
    private var listener: NWListener?
    private var listenerPort: Int?
    private var activeConnections: [UUID: MobileHostConnection] = [:]
    private var lastErrorDescription: String?

    private init() {}

    func start() {
        guard listener == nil else {
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let nextListener = try makeListener(parameters: parameters)
            nextListener.stateUpdateHandler = { state in
                Task { @MainActor in
                    MobileHostService.shared.handleListenerState(state)
                }
            }
            nextListener.newConnectionHandler = { connection in
                Task { @MainActor in
                    MobileHostService.shared.accept(connection)
                }
            }
            listener = nextListener
            listenerPort = nextListener.port.map { Int($0.rawValue) }
            nextListener.start(queue: callbackQueue)
        } catch {
            lastErrorDescription = String(describing: error)
            mobileHostLog.error("mobile host listener failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    private func makeListener(parameters: NWParameters) throws -> NWListener {
        if let preferredPort = NWEndpoint.Port(rawValue: UInt16(Self.preferredPort)),
           let listener = try? NWListener(using: parameters, on: preferredPort) {
            return listener
        }
        mobileHostLog.info("mobile host preferred port unavailable, falling back to an ephemeral port")
        return try NWListener(using: parameters, on: .any)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listenerPort = nil
        for connection in activeConnections.values {
            Task { await connection.close(reason: "service stopped") }
        }
        activeConnections.removeAll()
    }

    func statusSnapshot() -> MobileHostServiceStatus {
        let routes = listenerPort.map { routeResolver.routes(port: $0).routes } ?? []
        return MobileHostServiceStatus(
            isRunning: listener != nil && listenerPort != nil,
            port: listenerPort,
            routes: routes,
            activeConnectionCount: activeConnections.count,
            lastErrorDescription: lastErrorDescription
        )
    }

    func createAttachTicket(
        workspaceID: String,
        terminalID: String?,
        ttl: TimeInterval
    ) throws -> [String: Any] {
        let status = statusSnapshot()
        let ticket = try ticketStore.createTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            routes: status.routes,
            ttl: ttl
        )
        return try ticketStore.payload(for: ticket)
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let session = MobileHostConnection(
            id: id,
            connection: connection,
            handleRequest: { request in
                await TerminalController.shared.mobileHostHandleRPC(request)
            },
            onClose: { id in
                await MobileHostService.shared.removeConnection(id: id)
            }
        )
        activeConnections[id] = session
        Task { await session.start() }
    }

    private func removeConnection(id: UUID) {
        activeConnections.removeValue(forKey: id)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            listenerPort = listener?.port.map { Int($0.rawValue) }
            lastErrorDescription = nil
            mobileHostLog.info("mobile host listener ready on port \(self.listenerPort ?? 0)")
        case let .failed(error):
            lastErrorDescription = String(describing: error)
            mobileHostLog.error("mobile host listener failed: \(String(describing: error), privacy: .public)")
            listener?.cancel()
            listener = nil
            listenerPort = nil
        case .cancelled:
            listener = nil
            listenerPort = nil
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }
}

private actor MobileHostConnection {
    private let id: UUID
    private let connection: NWConnection
    private let callbackQueue: DispatchQueue
    private let handleRequest: @Sendable (MobileHostRPCRequest) async -> MobileHostRPCResult
    private let onClose: @Sendable (UUID) async -> Void
    private var receiveBuffer = Data()
    private var isClosed = false

    init(
        id: UUID,
        connection: NWConnection,
        handleRequest: @escaping @Sendable (MobileHostRPCRequest) async -> MobileHostRPCResult,
        onClose: @escaping @Sendable (UUID) async -> Void
    ) {
        self.id = id
        self.connection = connection
        self.callbackQueue = DispatchQueue(label: "dev.cmux.mobile.host-connection.\(id.uuidString)")
        self.handleRequest = handleRequest
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [id] state in
            Task { await self.handleState(state, connectionID: id) }
        }
        connection.start(queue: callbackQueue)
        receiveNext()
    }

    func close(reason: String) {
        guard !isClosed else {
            return
        }
        isClosed = true
        mobileHostLog.info("mobile host connection closed \(self.id.uuidString, privacy: .public): \(reason, privacy: .public)")
        connection.cancel()
        Task { await onClose(id) }
    }

    private func receiveNext() {
        guard !isClosed else {
            return
        }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { data, _, isComplete, error in
            let errorDescription = error.map { String(describing: $0) }
            Task {
                await self.handleReceive(
                    data: data,
                    isComplete: isComplete,
                    errorDescription: errorDescription
                )
            }
        }
    }

    private func handleReceive(
        data: Data?,
        isComplete: Bool,
        errorDescription: String?
    ) async {
        if let errorDescription {
            close(reason: errorDescription)
            return
        }

        if let data, !data.isEmpty {
            receiveBuffer.append(data)
            do {
                let frames = try MobileSyncFrameCodec.decodeFrames(from: &receiveBuffer)
                for frame in frames {
                    await respond(to: frame)
                }
            } catch {
                await sendResponse(
                    MobileHostRPCEnvelope.error(
                        id: nil,
                        code: "frame_decode_error",
                        message: "Invalid frame"
                    )
                )
                close(reason: "frame decode error")
                return
            }
        }

        if isComplete {
            close(reason: "remote closed")
        } else {
            receiveNext()
        }
    }

    private func respond(to frame: Data) async {
        switch MobileHostRPCEnvelope.decodeRequest(frame) {
        case let .success(request):
            let result = await handleRequest(request)
            await sendResponse(MobileHostRPCEnvelope.encodeResponse(id: request.id, result: result))
        case let .failure(error):
            await sendResponse(MobileHostRPCEnvelope.encodeResponse(id: nil, result: .failure(error)))
        }
    }

    private func sendResponse(_ response: Data) async {
        guard !isClosed else {
            return
        }
        let frame: Data
        do {
            frame = try MobileSyncFrameCodec.encodeFrame(response)
        } catch {
            close(reason: "response frame encode failed")
            return
        }

        connection.send(
            content: frame,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { error in
                if let error {
                    Task { await self.close(reason: String(describing: error)) }
                }
            }
        )
    }

    private func handleState(_ state: NWConnection.State, connectionID: UUID) {
        switch state {
        case .failed(let error):
            close(reason: String(describing: error))
        case .cancelled:
            close(reason: "cancelled")
        case .ready:
            mobileHostLog.debug("mobile host connection ready \(connectionID.uuidString, privacy: .public)")
        case .setup, .waiting, .preparing:
            break
        @unknown default:
            break
        }
    }
}
