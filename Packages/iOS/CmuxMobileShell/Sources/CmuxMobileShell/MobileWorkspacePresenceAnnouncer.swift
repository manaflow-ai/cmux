public import CMUXMobileCore
import CmuxWorkspacePresence
import Foundation

/// Owns one cancellable iOS workspace-view session and its auth generation.
@MainActor
public final class MobileWorkspacePresenceAnnouncer: WorkspacePresenceAnnouncing {
    private let transport: WorkspacePresenceWebSocket
    private let tokenSource: PresenceTokenSource
    private var session: WorkspacePresenceSession
    private var runTask: Task<Void, Never>?
    private var scope: WorkspacePresenceScope?
    private var accountID: String?
    private var generation: UInt64 = 0

    deinit { runTask?.cancel() }

    /// Creates a lease publisher, or nil when the service origin is invalid.
    public init?(
        serviceBaseURL: String,
        tokenSource: PresenceTokenSource,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        guard let url = URL(string: serviceBaseURL),
              url.user == nil, url.password == nil,
              url.scheme == "https"
                || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")) else {
            return nil
        }
        transport = WorkspacePresenceWebSocket(baseURL: url)
        self.tokenSource = tokenSource
        _ = teamIDProvider // Cloud team authority is carried by the validated scope.
        session = WorkspacePresenceSession(transport: transport)
    }

    /// Replaces the active workspace lease. An unchanged scope is a no-op.
    public func setWorkspaceScope(_ nextScope: WorkspacePresenceScope?) async {
        guard nextScope != scope else { return }
        generation &+= 1
        let currentGeneration = generation
        runTask?.cancel()
        runTask = nil
        session.stop()
        scope = nextScope
        accountID = await tokenSource.currentUserID()
        guard let nextScope, self.scope == nextScope, generation == currentGeneration else { return }
        session.setViewing(true)
        let session = self.session
        let tokenSource = self.tokenSource
        runTask = Task { @MainActor [weak self, session, tokenSource] in
            await session.run(
                scope: nextScope,
                accessToken: {
                    guard let accountID = self?.accountID else { return nil }
                    return await tokenSource.accessToken(expectedUserID: accountID)
                },
                isCurrent: {
                    self?.generation == currentGeneration && self?.scope == nextScope
                }
            )
        }
    }

    /// Updates the lease when the mobile scene enters or leaves the foreground.
    public func setWorkspaceViewing(_ active: Bool) {
        session.setViewing(active)
    }
}
