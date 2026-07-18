import CmuxTerminalBackend
import Foundation
import Testing

actor ScriptedBackendTransport: BackendPeerIdentityTransport {
    private static let statePreservingCommands: Set<String> = [
        "identify",
        "list-presentations",
        "list-projection-states",
        "list-workspaces",
        "ping",
        "process-info",
        "read-screen",
        "renderer-workers",
        "subscribe-topology",
        "terminal-accessibility-activate-link",
        "terminal-accessibility-snapshot",
        "terminal-activity-snapshot",
        "terminal-request-status",
        "terminal-state",
        "topology-snapshot",
    ]

    private var connected = false
    private var closed = false
    private var inbound: [Data] = []
    private var outbound: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Void, any Error>] = []
    private var sendWaiters: [CheckedContinuation<Data, Never>] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var failNextSend = false
    private var sentCommandLog: [String] = []
    private var simulatedStateDigest: UInt64 = 0xcbf2_9ce4_8422_2325
    private var beforeNextReceiveReturns: (@Sendable () -> Void)?
    private var scriptedPeerIdentity = BackendPeerIdentity(
        processID: 42,
        userID: 501,
        auditToken: BackendAuditToken(
            word0: 1, word1: 2, word2: 3, word3: 4,
            word4: 5, word5: 6, word6: 7, word7: 8
        )
    )

    func connect() async throws {
        guard !connected else { throw BackendProtocolError.alreadyConnected }
        connected = true
    }

    func peerIdentity() async throws -> BackendPeerIdentity {
        guard connected, !closed else { throw BackendProtocolError.notConnected }
        return scriptedPeerIdentity
    }

    func setPeerIdentity(_ identity: BackendPeerIdentity) {
        scriptedPeerIdentity = identity
    }

    func send(_ message: Data) async throws {
        guard connected, !closed else { throw BackendProtocolError.notConnected }
        if failNextSend {
            failNextSend = false
            throw BackendProtocolError.connectionClosed
        }
        if let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
           let command = object["cmd"] as? String {
            sentCommandLog.append(command)
            if !Self.statePreservingCommands.contains(command) {
                for byte in message {
                    simulatedStateDigest = (simulatedStateDigest ^ UInt64(byte))
                        &* 0x0000_0100_0000_01b3
                }
            }
        }
        if let waiter = sendWaiters.first {
            sendWaiters.removeFirst()
            waiter.resume(returning: message)
        } else {
            outbound.append(message)
        }
    }

    func receive() async throws -> Data {
        guard connected, !closed else { throw BackendProtocolError.connectionClosed }
        while inbound.isEmpty {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                receiveWaiters.append(continuation)
            }
            guard connected, !closed else { throw BackendProtocolError.connectionClosed }
        }
        let message = inbound.removeFirst()
        let beforeReturn = beforeNextReceiveReturns
        beforeNextReceiveReturns = nil
        beforeReturn?()
        return message
    }

    func close() async {
        guard !closed else { return }
        closed = true
        for waiter in receiveWaiters {
            waiter.resume(throwing: BackendProtocolError.connectionClosed)
        }
        receiveWaiters.removeAll()
        for waiter in closeWaiters {
            waiter.resume()
        }
        closeWaiters.removeAll()
    }

    func enqueue(_ message: Data) {
        inbound.append(message)
        if let waiter = receiveWaiters.first {
            receiveWaiters.removeFirst()
            waiter.resume()
        }
    }

    func runBeforeNextReceiveReturns(_ action: @escaping @Sendable () -> Void) {
        beforeNextReceiveReturns = action
    }

    func injectNextSendFailure() {
        failNextSend = true
    }

    func nextSent() async -> Data {
        if !outbound.isEmpty {
            return outbound.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            sendWaiters.append(continuation)
        }
    }

    func sentCount() -> Int {
        outbound.count
    }

    /// Complete command history, including requests consumed by `nextSent()`.
    func commandLog() -> [String] {
        sentCommandLog
    }

    /// Deterministic fake-server digest changed only by dispatched mutations.
    func stateDigest() -> UInt64 {
        simulatedStateDigest
    }

    func waitUntilClosed() async {
        if closed { return }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }
}

func encodedJSON(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func requestID(in data: Data) throws -> UInt64 {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let number = object?["id"] as? NSNumber
    return try #require(number?.uint64Value)
}
