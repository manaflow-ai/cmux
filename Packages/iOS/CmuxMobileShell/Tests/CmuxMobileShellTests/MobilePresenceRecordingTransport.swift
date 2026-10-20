import CMUXMobileCore
import CmuxWorkspacePresence

actor MobilePresenceRecordingTransport: WorkspacePresenceConnecting {
    private let tokens: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() { (tokens, continuation) = AsyncStream.makeStream() }

    func connect(scope: WorkspacePresenceScope, accessToken: String) async throws -> any WorkspacePresenceConnection {
        continuation.yield(accessToken)
        throw CancellationError()
    }

    func nextToken() async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { [tokens] in
                for await token in tokens { return token }
                return nil
            }
            group.addTask {
                try? await ContinuousClock().sleep(for: .seconds(3))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }
}
