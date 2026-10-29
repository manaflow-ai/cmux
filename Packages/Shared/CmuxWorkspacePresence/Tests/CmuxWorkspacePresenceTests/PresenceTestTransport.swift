import CMUXMobileCore
import CmuxWorkspacePresence

actor PresenceTestTransport: WorkspacePresenceConnecting {
    struct Opened: Sendable {
        let scope: WorkspacePresenceScope
        let connection: PresenceTestConnection
    }

    nonisolated let connections: AsyncStream<Opened>
    private let continuation: AsyncStream<Opened>.Continuation

    init() {
        (connections, continuation) = AsyncStream.makeStream()
    }

    func connect(scope: WorkspacePresenceScope, accessToken: String) async throws -> any WorkspacePresenceConnection {
        let connection = PresenceTestConnection()
        continuation.yield(Opened(scope: scope, connection: connection))
        return connection
    }

    static func next<Value: Sendable>(
        _ stream: AsyncStream<Value>,
        matching predicate: @escaping @Sendable (Value) -> Bool = { _ in true }
    ) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask {
                for await value in stream where predicate(value) { return value }
                return nil
            }
            group.addTask {
                // A test failure deadline, never a production synchronization delay.
                try? await ContinuousClock().sleep(for: .seconds(3))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    static func finishes<Value: Sendable>(_ stream: AsyncStream<Value>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {}
                return true
            }
            group.addTask {
                try? await ContinuousClock().sleep(for: .seconds(3))
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }
}
