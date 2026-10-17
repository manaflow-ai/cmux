import CmuxAuthRuntime
import CmuxConversation
import CmuxConversationHost
import CryptoKit
import Foundation

/// App-owned provider processes and journals, partitioned by authenticated
/// account and app bundle. No state is read from terminal session discovery.
@MainActor
final class NativeConversationService {
    private let auth: AuthCoordinator
    private let directory: URL
    private var runtime: ConversationBroker?
    private(set) var artifacts = NativeConversationArtifactStore()
    private var identity: AuthenticatedSessionIdentity?
    private var observationTask: Task<Void, Never>?
    private var retirementTask: Task<Void, Never>?
    private var isShuttingDown = false

    init(auth: AuthCoordinator, directory: URL) {
        self.auth = auth
        self.directory = directory
        let identities = auth.authenticatedSessionIdentities()
        observationTask = Task { [weak self] in
            for await identity in identities {
                guard !Task.isCancelled, let self else { return }
                await self.accountDidChange(identity)
            }
        }
    }

    var hasRuntime: Bool { runtime != nil }

    func currentRuntime() async throws -> (ConversationBroker, AuthenticatedSessionIdentity) {
        await auth.awaitBootstrapped()
        guard !isShuttingDown, let current = auth.authenticatedSessionIdentity else {
            throw NativeConversationError.unauthenticated
        }
        if let runtime, identity == current { return (runtime, current) }
        await accountDidChange(current)
        await retirementTask?.value
        guard !isShuttingDown, auth.isAuthenticatedSessionIdentityCurrent(current) else {
            throw NativeConversationError.unauthenticated
        }
        if let runtime, identity == current { return (runtime, current) }
        let account = SHA256.hash(data: Data(current.accountID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let broker = try ConversationBroker(
            directory: directory.appendingPathComponent(account, isDirectory: true),
            onChange: { sessionID, cursor in
                MobileHostService.emitEvent(topic: "mobile.conversation.changed", payload: [
                    "session_id": sessionID.rawValue,
                    "cursor": cursor,
                ])
            }
        )
        runtime = broker
        identity = current
        return (broker, current)
    }

    func isCurrent(_ identity: AuthenticatedSessionIdentity) -> Bool {
        !isShuttingDown && self.identity == identity && auth.isAuthenticatedSessionIdentityCurrent(identity)
    }

    func shutdown() async {
        isShuttingDown = true
        observationTask?.cancel()
        observationTask = nil
        let previous = runtime
        runtime = nil
        identity = nil
        artifacts = NativeConversationArtifactStore()
        await retirementTask?.value
        retirementTask = nil
        await previous?.shutdown()
    }

    private func accountDidChange(_ next: AuthenticatedSessionIdentity?) async {
        guard next == auth.authenticatedSessionIdentity else { return }
        guard identity != next else { return }
        let previous = runtime
        runtime = nil
        identity = nil
        artifacts = NativeConversationArtifactStore()
        if let previous {
            let retiring = retirementTask
            retirementTask = Task {
                await retiring?.value
                await previous.shutdown()
            }
        }
        await retirementTask?.value
    }
}

enum NativeConversationError: Error {
    case unauthenticated
    case invalidScope
    case invalidPayload
    case unsupportedTarget
}
