import Foundation
@preconcurrency import Network

// Wraps NWConnection, whose callbacks are delivered on the Network framework's
// queue; the adapter owns no mutable state beyond the underlying connection.
final class MobileHostNWConnectionAdapter: MobileHostByteConnection, @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func setStateUpdateHandler(_ handler: ((MobileHostByteConnectionState) -> Void)?) {
        connection.stateUpdateHandler = { state in
            handler?(Self.mapState(state))
        }
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
    }

    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping (Data?, Bool, String?) -> Void
    ) {
        connection.receive(
            minimumIncompleteLength: minimumIncompleteLength,
            maximumLength: maximumLength
        ) { data, _, isComplete, error in
            completion(data, isComplete, error.map { String(describing: $0) })
        }
    }

    func send(_ data: Data, completion: @escaping (String?) -> Void) {
        connection.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { error in
                completion(error.map { String(describing: $0) })
            }
        )
    }

    func close() {
        connection.cancel()
    }

    private static func mapState(_ state: NWConnection.State) -> MobileHostByteConnectionState {
        switch state {
        case .setup:
            return .setup
        case .waiting:
            return .waiting
        case .preparing:
            return .preparing
        case .ready:
            return .ready
        case let .failed(error):
            return .failed(String(describing: error))
        case .cancelled:
            return .cancelled
        @unknown default:
            return .waiting
        }
    }
}
