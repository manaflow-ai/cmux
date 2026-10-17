import CmuxAuthRuntime
import CmuxConversation
import CmuxConversationHost
import CryptoKit
import Foundation

/// App-owned provider processes and journals, partitioned by authenticated
/// account and app bundle. No state is read from terminal session discovery.
@MainActor
final class NativeConversationService {
    typealias BrokerLoader = @Sendable (URL) async throws -> ConversationBroker

    private struct LoadingRuntime {
        let id: UUID
        let task: Task<ConversationBroker, any Error>
    }

    private let auth: AuthCoordinator
    private let directory: URL
    private let loadBroker: BrokerLoader
    private var runtime: ConversationBroker?
    private var loadingRuntime: LoadingRuntime?
    private(set) var artifacts = NativeConversationArtifactStore()
    private var identity: AuthenticatedSessionIdentity?
    private var observationTask: Task<Void, Never>?
    private var retirementTask: Task<Void, Never>?
    private var isShuttingDown = false

    init(
        auth: AuthCoordinator,
        directory: URL,
        loadBroker: @escaping BrokerLoader = { directory in
            try await NativeConversationService.loadFromDisk(directory)
        }
    ) {
        self.auth = auth
        self.directory = directory
        self.loadBroker = loadBroker
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
        guard !isShuttingDown, identity == current, auth.isAuthenticatedSessionIdentityCurrent(current) else {
            throw NativeConversationError.unauthenticated
        }
        if let runtime, identity == current { return (runtime, current) }
        let account = SHA256.hash(data: Data(current.accountID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        if loadingRuntime == nil {
            let path = directory.appendingPathComponent(account, isDirectory: true)
            let loader = loadBroker
            loadingRuntime = LoadingRuntime(id: UUID(), task: Task { try await loader(path) })
        }
        let loading = loadingRuntime!
        do {
            let broker = try await loading.task.value
            guard !isShuttingDown, identity == current, auth.isAuthenticatedSessionIdentityCurrent(current) else {
                // Retirement owns the late result and closes it before another
                // identity can open the same account directory.
                throw NativeConversationError.unauthenticated
            }
            if let runtime { return (runtime, current) }
            guard loadingRuntime?.id == loading.id else { throw NativeConversationError.unauthenticated }
            runtime = broker
            loadingRuntime = nil
            return (broker, current)
        } catch {
            if loadingRuntime?.id == loading.id { loadingRuntime = nil }
            throw error
        }
    }

    func isCurrent(_ identity: AuthenticatedSessionIdentity) -> Bool {
        !isShuttingDown && self.identity == identity && auth.isAuthenticatedSessionIdentityCurrent(identity)
    }

    func shutdown() async {
        isShuttingDown = true
        observationTask?.cancel()
        observationTask = nil
        retireRuntime(nextIdentity: nil)
        await retirementTask?.value
        retirementTask = nil
    }

    private func accountDidChange(_ next: AuthenticatedSessionIdentity?) async {
        guard !isShuttingDown, next == auth.authenticatedSessionIdentity else { return }
        // A token refresh temporarily hides admission identity while keeping
        // the authenticated generation valid. It must not stop provider work.
        if next == nil, let identity, auth.isAuthenticatedSessionIdentityCurrent(identity) { return }
        guard identity != next else { return }
        retireRuntime(nextIdentity: next)
        await retirementTask?.value
    }

    private func retireRuntime(nextIdentity: AuthenticatedSessionIdentity?) {
        let previous = runtime
        let loading = loadingRuntime?.task
        runtime = nil
        loadingRuntime = nil
        identity = nextIdentity
        artifacts = NativeConversationArtifactStore()
        loading?.cancel()
        if previous != nil || loading != nil {
            let retiring = retirementTask
            retirementTask = Task {
                await retiring?.value
                await previous?.shutdown()
                if let loading, let broker = try? await loading.value {
                    await broker.shutdown()
                }
            }
        }
    }

    private nonisolated static func loadFromDisk(_ directory: URL) async throws -> ConversationBroker {
        // Journal validation and replay can read many megabytes. Keep that
        // synchronous initialization away from the app's main actor.
        try await Task.detached(priority: .utility) {
            try ConversationBroker(directory: directory, onChange: { sessionID, cursor in
                MobileHostService.emitEvent(topic: "mobile.conversation.changed", payload: [
                    "session_id": sessionID.rawValue,
                    "cursor": cursor,
                ])
            })
        }.value
    }
}

enum NativeConversationError: Error {
    case unauthenticated
    case invalidScope
    case invalidPayload
    case unsupportedTarget
}
