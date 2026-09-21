public import CMUXMobileCore
import CmuxWorkspacePresence
import Foundation

/// Publishes one phone's active workspace through a separate, account-scoped
/// viewing lease. Device reachability presence stays owned by the legacy client.
public actor MobileWorkspacePresenceAnnouncer: WorkspacePresenceAnnouncing {
    private let connector: any WorkspacePresenceConnecting
    private let tokenSource: PresenceTokenSource
    private var connection: (any WorkspacePresenceConnection)?
    private var leaseTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private var scope: WorkspacePresenceScope?
    private var accountID: String?

    /// Creates a lease publisher for the configured presence origin.
    /// - Parameters:
    ///   - serviceBaseURL: Worker origin for `/v1/workspace-presence`.
    ///   - tokenSource: Account-scoped Stack token source.
    ///   - teamIDProvider: Selected team used for Cloud workspace scopes.
    public init(
        serviceBaseURL: String,
        tokenSource: PresenceTokenSource,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.connector = WorkspacePresenceWebSocket(baseURL: URL(string: serviceBaseURL) ?? URL(string: "http://127.0.0.1")!)
        self.tokenSource = tokenSource
        _ = teamIDProvider // Team membership is carried in the validated scope.
    }

    /// Replaces the active workspace lease. `nil` closes the old lease first.
    public func setWorkspaceScope(_ scope: WorkspacePresenceScope?) async {
        generation &+= 1
        let currentGeneration = generation
        leaseTask?.cancel()
        leaseTask = nil
        connection?.close()
        connection = nil
        self.scope = scope
        accountID = await tokenSource.currentUserID()
        guard scope != nil else { return }
        leaseTask = Task { [weak self] in
            await self?.runLeaseLoop(generation: currentGeneration)
        }
    }

    private func runLeaseLoop(generation expectedGeneration: UInt64) async {
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled, generation == expectedGeneration, let scope {
            guard let accountID,
                  let token = await tokenSource.accessToken(expectedUserID: accountID) else {
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(60))
                continue
            }
            do {
                let opened = try await connector.connect(scope: scope, accessToken: token)
                guard generation == expectedGeneration, self.scope == scope else {
                    opened.close()
                    return
                }
                connection = opened
                revision &+= 1
                try await opened.sendViewing(true, revision: revision)
                backoff = .seconds(1)
                while !Task.isCancelled, generation == expectedGeneration, self.scope == scope {
                    try await Task.sleep(for: .seconds(15))
                    revision &+= 1
                    try await opened.sendViewing(true, revision: revision)
                }
                opened.close()
                connection = nil
            } catch is CancellationError {
                return
            } catch {
                connection?.close()
                connection = nil
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(60))
            }
        }
    }
}
