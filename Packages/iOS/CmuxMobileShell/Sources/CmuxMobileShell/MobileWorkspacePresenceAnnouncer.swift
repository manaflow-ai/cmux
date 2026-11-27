public import CMUXMobileCore
import CmuxWorkspacePresence
import Foundation

/// Owns one cancellable iOS workspace-view session and its auth generation.
@MainActor
public final class MobileWorkspacePresenceAnnouncer: WorkspacePresenceAnnouncing {
    private let tokenSource: PresenceTokenSource
    private var session: WorkspacePresenceSession
    private var runTask: Task<Void, Never>?
    private(set) var scope: WorkspacePresenceScope?
    private var accountID: String?
    private var generation: UInt64 = 0
    private var selectionRequest = UUID()
    private var isViewing = true

    deinit { runTask?.cancel() }

    /// Creates a lease publisher, or nil when the service origin is invalid.
    public convenience init?(
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
        _ = teamIDProvider // Cloud team authority is carried by the validated scope.
        self.init(transport: WorkspacePresenceWebSocket(baseURL: url), tokenSource: tokenSource)
    }

    init(transport: any WorkspacePresenceConnecting, tokenSource: PresenceTokenSource) {
        self.tokenSource = tokenSource
        session = WorkspacePresenceSession(transport: transport)
    }

    /// Replaces the active workspace lease, including when the account changes.
    public func setWorkspaceScope(_ nextScope: WorkspacePresenceScope?) async {
        let request = UUID()
        selectionRequest = request
        // Retire a departing room before awaiting identity, including sign-out.
        if nextScope != scope || nextScope == nil {
            generation &+= 1
            runTask?.cancel()
            runTask = nil
            session.stop()
            scope = nextScope
            accountID = nil
        }
        guard let nextScope else { return }
        let nextAccountID = await tokenSource.currentUserID()
        guard selectionRequest == request, !Task.isCancelled else { return }
        guard nextAccountID != accountID || runTask == nil else { return }
        generation &+= 1
        let currentGeneration = generation
        runTask?.cancel()
        runTask = nil
        session.stop()
        scope = nextScope
        accountID = nextAccountID
        guard let accountID = nextAccountID else { return }
        session.setViewing(isViewing)
        let session = self.session
        let tokenSource = self.tokenSource
        runTask = Task { @MainActor [weak self, session, tokenSource, accountID] in
            await session.run(
                scope: nextScope,
                accessToken: {
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
        isViewing = active
        session.setViewing(active)
    }
}
