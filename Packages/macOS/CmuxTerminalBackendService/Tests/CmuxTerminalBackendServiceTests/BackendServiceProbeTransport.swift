import CmuxTerminalBackend
import Foundation

enum BackendServiceProbeConnectBehavior: Sendable {
    case succeed
    case block
    case posixFailure(Int32)
    case protocolFailure(BackendProtocolError)
}

actor BackendServiceProbeTransport: BackendPeerIdentityTransport {
    private struct Request: Decodable {
        let id: UInt64
        let cmd: String
    }

    private let payloads: [String: Data]
    private let responds: Bool
    private let connectBehavior: BackendServiceProbeConnectBehavior
    private let disconnectOnCommand: String?
    private let blocksOnClose: Bool
    private let peerIdentityValue: BackendPeerIdentity
    private var connected = false
    private var closed = false
    private var closeStarted = false
    private var closeReleased = false
    private var inbound: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data, any Error>] = []
    private var connectContinuation: CheckedContinuation<Void, any Error>?
    private var closeStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        payloads: [String: Data],
        responds: Bool = true,
        connectBehavior: BackendServiceProbeConnectBehavior = .succeed,
        disconnectOnCommand: String? = nil,
        blocksOnClose: Bool = false,
        peerIdentity: BackendPeerIdentity = BackendPeerIdentity(
            processID: 42,
            userID: 501,
            auditToken: testBackendAuditToken(processID: 42, userID: 501)
        )
    ) {
        self.payloads = payloads
        self.responds = responds
        self.connectBehavior = connectBehavior
        self.disconnectOnCommand = disconnectOnCommand
        self.blocksOnClose = blocksOnClose
        peerIdentityValue = peerIdentity
    }

    func connect() async throws {
        switch connectBehavior {
        case .succeed:
            break
        case .block:
            try await withCheckedThrowingContinuation { continuation in
                connectContinuation = continuation
            }
        case let .posixFailure(code):
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        case let .protocolFailure(error):
            throw error
        }
        connected = true
    }

    func send(_ message: Data) throws {
        guard connected, !closed else { throw BackendProtocolError.notConnected }
        guard responds else { return }
        let request = try JSONDecoder().decode(Request.self, from: message)
        if request.cmd == disconnectOnCommand {
            throw BackendProtocolError.connectionClosed
        }
        guard let payload = payloads[request.cmd] else {
            throw BackendProtocolError.server("unexpected test command \(request.cmd)")
        }
        let payloadObject = try JSONSerialization.jsonObject(with: payload)
        let response = try JSONSerialization.data(
            withJSONObject: [
                "id": request.id,
                "ok": true,
                "data": payloadObject,
            ],
            options: [.sortedKeys]
        )
        if let waiter = receiveWaiters.first {
            receiveWaiters.removeFirst()
            waiter.resume(returning: response)
        } else {
            inbound.append(response)
        }
    }

    func peerIdentity() throws -> BackendPeerIdentity {
        guard connected, !closed else { throw BackendProtocolError.notConnected }
        return peerIdentityValue
    }

    func receive() async throws -> Data {
        guard connected, !closed else { throw BackendProtocolError.connectionClosed }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func close() async {
        guard !closed else { return }
        if blocksOnClose, !closeReleased {
            closeStarted = true
            for waiter in closeStartedWaiters {
                waiter.resume()
            }
            closeStartedWaiters.removeAll()
            await withCheckedContinuation { continuation in
                closeReleaseWaiters.append(continuation)
            }
        }
        guard !closed else { return }
        closed = true
        connectContinuation?.resume(throwing: CancellationError())
        connectContinuation = nil
        for waiter in receiveWaiters {
            waiter.resume(throwing: CancellationError())
        }
        receiveWaiters.removeAll()
    }

    func waitUntilCloseStarts() async {
        guard !closeStarted else { return }
        await withCheckedContinuation { continuation in
            closeStartedWaiters.append(continuation)
        }
    }

    func releaseClose() {
        closeReleased = true
        for waiter in closeReleaseWaiters {
            waiter.resume()
        }
        closeReleaseWaiters.removeAll()
    }

    func isClosed() -> Bool {
        closed
    }
}
