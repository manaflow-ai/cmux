public import Observation

/// Defers authorization publication until a main window completes its initial display.
///
/// Delivery decisions can finish before readiness. Their state is retained here,
/// and only the latest outcome is published when the window opens the gate.
@MainActor
@Observable
public final class NotificationAuthorizationRefreshCoordinator {
    private var isWindowSetupComplete = false
    private var hasPendingRefresh = false
    private var pendingState: NotificationAuthorizationState?
    private var publishedState: NotificationAuthorizationState = .unknown
    @ObservationIgnored private let statusProvider: @MainActor () async -> Result<UserNotificationAuthorizationStatus, UserNotificationCenterFailure>
    @ObservationIgnored private let publish: @MainActor (NotificationAuthorizationState) -> Void

    /// Creates the single owner of refresh deferral and authorization publication.
    /// - Parameters:
    ///   - statusProvider: Reads the notification service without publishing UI state.
    ///   - publish: Adapts changed, ready outcomes to the app's observable state.
    public init(
        statusProvider: @escaping @MainActor () async -> Result<UserNotificationAuthorizationStatus, UserNotificationCenterFailure>,
        publish: @escaping @MainActor (NotificationAuthorizationState) -> Void
    ) {
        self.statusProvider = statusProvider
        self.publish = publish
    }

    /// Opens the gate once and starts the coalesced refresh, if requested.
    /// - Returns: The deferred refresh task, or nil when none remains.
    @discardableResult
    public func markWindowSetupComplete() -> Task<Void, Never>? {
        guard !isWindowSetupComplete else { return nil }
        isWindowSetupComplete = true
        if let pendingState {
            self.pendingState = nil
            accept(pendingState)
        }
        guard hasPendingRefresh else { return nil }
        hasPendingRefresh = false
        return refresh()
    }

    /// Coalesces pre-setup refreshes, or reads and publishes through the shared gate.
    /// - Returns: A task callers can await for an admitted read.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        guard isWindowSetupComplete else {
            hasPendingRefresh = true
            return Task {}
        }
        return Task { @MainActor [weak self, statusProvider] in
            let result = await statusProvider()
            guard let self else { return }
            switch result {
            case .success(let status): accept(NotificationAuthorizationState(status: status))
            case .failure: accept(.unknown)
            }
        }
    }

    /// Retains an early delivery outcome or publishes a changed ready outcome.
    /// - Parameter state: The effective outcome, independent of the UI's cached state.
    public func accept(_ state: NotificationAuthorizationState) {
        guard isWindowSetupComplete else {
            pendingState = state
            return
        }
        guard state != publishedState else { return }
        publishedState = state
        publish(state)
    }
}
