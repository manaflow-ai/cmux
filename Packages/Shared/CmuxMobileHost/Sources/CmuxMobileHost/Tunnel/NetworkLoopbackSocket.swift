import CmuxLink
import Foundation
@preconcurrency import Network

/// An `NWConnection` to this Mac's loopback behind async calls.
final class NetworkLoopbackSocket: MobileLoopbackSocket, @unchecked Sendable {
    private let connection: NWConnection

    private init(connection: NWConnection) {
        self.connection = connection
    }

    static func connect(host: NWEndpoint.Host, port: NWEndpoint.Port, timeout: Duration,
                        clock: LinkClock) async throws -> NetworkLoopbackSocket {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        parameters.requiredInterfaceType = .loopback
        let connection = NWConnection(host: host, port: port, using: parameters)
        let outcome = ConnectOutcome()
        let deadline = Task {
            try? await clock.sleep(for: timeout)
            await outcome.finish(.failure(.timedOut))
        }
        defer { deadline.cancel() }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: Task { await outcome.finish(.success(())) }
            // `.waiting` is Network.framework retrying (refused); a forward answers now.
            case .waiting(let error), .failed(let error): Task { await outcome.finish(.failure(Self.refusal(error))) }
            case .cancelled: Task { await outcome.finish(.failure(.failed)) }
            default: break
            }
        }
        // carve-out: Network.framework delivers callbacks on a queue it is given.
        connection.start(queue: DispatchQueue(label: "dev.cmux.mobile.tunnel"))
        let result = await withTaskCancellationHandler {
            await outcome.wait()
        } onCancel: {
            Task { await outcome.finish(.failure(.failed)) }
        }
        connection.stateUpdateHandler = nil
        switch result {
        case .success:
            return NetworkLoopbackSocket(connection: connection)
        case .failure(let error):
            connection.cancel()
            throw error
        }
    }

    private static func refusal(_ error: NWError) -> MobileLoopbackConnectError {
        if case .posix(let code) = error, code == .ECONNREFUSED { return .refused }
        if case .posix(let code) = error, code == .ETIMEDOUT { return .timedOut }
        return .failed
    }

    func read(maximum: Int) async throws -> Data? {
        while true {
            let chunk = try await readOnce(maximum: maximum)
            if chunk?.isEmpty != true { return chunk }
        }
    }

    private func readOnce(maximum: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximum)) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func finishWriting() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    func close() async {
        connection.cancel()
    }
}
