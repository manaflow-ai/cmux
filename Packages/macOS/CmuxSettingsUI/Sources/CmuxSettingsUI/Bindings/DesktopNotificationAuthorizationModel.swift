import Observation

/// `@Observable` view-model for the host's live macOS notification permission state.
@MainActor
@Observable
final class DesktopNotificationAuthorizationModel {
    /// The most recent authorization state supplied by the host.
    private(set) var current: DesktopNotificationAuthorizationState = .unknown

    @ObservationIgnored private let currentStatus: () -> DesktopNotificationAuthorizationState
    @ObservationIgnored private let makeStream: () -> AsyncStream<DesktopNotificationAuthorizationState>
    @ObservationIgnored private let refreshStatus: () -> Void
    @ObservationIgnored private let driver = SettingReadDriver<DesktopNotificationAuthorizationState>()
    @ObservationIgnored private var hasStarted = false

    /// Creates a model bound to the host's desktop-notification authorization stream.
    ///
    /// - Parameter hostActions: The host bridge that supplies the current state,
    ///   refreshes from `UNUserNotificationCenter`, and emits later changes.
    convenience init(hostActions: SettingsHostActions) {
        self.init(
            currentStatus: { hostActions.desktopNotificationAuthorizationStatus() },
            makeStream: { hostActions.desktopNotificationAuthorizationStatusUpdates() },
            refreshStatus: { hostActions.refreshDesktopNotificationAuthorizationStatus() }
        )
    }

    init(
        currentStatus: @escaping () -> DesktopNotificationAuthorizationState,
        makeStream: @escaping () -> AsyncStream<DesktopNotificationAuthorizationState>,
        refreshStatus: @escaping () -> Void
    ) {
        self.currentStatus = currentStatus
        self.makeStream = makeStream
        self.refreshStatus = refreshStatus
    }

    /// Starts live observation and asks the host to refresh the OS permission state.
    func startObserving() {
        guard !hasStarted else { return }
        hasStarted = true
        current = currentStatus()
        driver.activate(makeStream) { [weak self] state in
            self?.current = state
        }
        refreshStatus()
    }
}
