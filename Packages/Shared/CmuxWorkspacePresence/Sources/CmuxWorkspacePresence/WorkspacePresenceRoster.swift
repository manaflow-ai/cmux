import CMUXMobileCore
import Foundation

/// Shares passive sidebar subscriptions while announcing only the selected workspace.
@MainActor
public final class WorkspacePresenceRoster {
    private let transport: any WorkspacePresenceConnecting
    private let clock: any Clock<Duration>
    private var accountID: String?
    private var teamID: String?
    private var generation = UUID()
    private var accessToken: @MainActor () async -> String? = { nil }
    private var isCurrent: @MainActor () -> Bool = { false }
    private var observed: Set<WorkspacePresenceScope> = []
    private var selected: WorkspacePresenceScope?
    private var isActive = false
    private var sessions: [WorkspacePresenceScope: WorkspacePresenceObservation] = [:]
    private var values: [WorkspacePresenceScope: [WorkspacePresenceParticipant]] = [:]
    private var continuations: [UUID: AsyncStream<WorkspacePresenceScope>.Continuation] = [:]

    /// Creates a roster without app, account, or filesystem dependencies.
    /// - Parameters:
    ///   - transport: Authenticated workspace connection factory.
    ///   - clock: Lease and reconnect clock; injectable in tests.
    public init(transport: any WorkspacePresenceConnecting, clock: any Clock<Duration> = ContinuousClock()) {
        self.transport = transport
        self.clock = clock
    }

    /// Retires the previous account generation before accepting any new snapshots.
    /// - Parameters:
    ///   - accountID: Verified account, or nil on sign-out.
    ///   - teamID: Verified team whose Cloud workspaces may be observed.
    ///   - accessToken: Obtains credentials only within the captured auth generation.
    ///   - isCurrent: Synchronously fences account, team, and session replacement.
    public func configure(
        accountID: String?,
        teamID: String?,
        accessToken: @escaping @MainActor () async -> String?,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        generation = UUID()
        for entry in sessions.values { entry.stop() }
        sessions.removeAll()
        let previous = Array(values.keys)
        values.removeAll()
        self.accountID = accountID
        self.teamID = teamID
        self.accessToken = accessToken
        self.isCurrent = isCurrent
        for scope in previous { publish(scope) }
        reconcile()
    }

    /// Reconciles mounted rows separately from the one workspace being viewed.
    /// - Parameters:
    ///   - observed: Visible sidebar rooms, deduplicated across windows.
    ///   - selected: The foreground window's workspace, even when its row is offscreen.
    ///   - isActive: False while the app is inactive; passive rows never announce viewing.
    public func setWorkspaces(observed: Set<WorkspacePresenceScope>, selected: WorkspacePresenceScope?, isActive: Bool) {
        self.observed = observed
        self.selected = selected
        self.isActive = isActive
        reconcile()
    }

    /// Returns only other authenticated viewers of this exact workspace.
    /// - Parameter scope: Canonical workspace identity.
    /// - Returns: An empty list when the captured auth generation is no longer current.
    public func collaborators(in scope: WorkspacePresenceScope) -> [WorkspacePresenceParticipant] {
        guard isCurrent() else { return [] }
        return values[scope, default: []].filter { $0.id != accountID }
    }

    /// Streams changed scopes so native rows can replace immutable UI snapshots.
    ///
    /// Read ``collaborators(in:)`` after subscribing and again for each matching event.
    public func changes() -> AsyncStream<WorkspacePresenceScope> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in self?.continuations[id] = nil }
            }
        }
    }

    private func reconcile() {
        var wanted = observed
        if let selected { wanted.insert(selected) }
        wanted = Set(wanted.filter { $0.kind == .mac || $0.teamID == teamID })
        if accountID == nil || !isCurrent() { wanted = [] }
        for scope in Array(sessions.keys) where !wanted.contains(scope) {
            sessions.removeValue(forKey: scope)?.stop()
            if values.removeValue(forKey: scope) != nil { publish(scope) }
        }
        // Withdraw the old selection before enabling its replacement.
        for (scope, entry) in sessions where scope != selected || !isActive {
            entry.session.setViewing(false)
        }
        for scope in wanted {
            if sessions[scope] == nil { start(scope) }
            sessions[scope]?.session.setViewing(isActive && scope == selected)
        }
    }

    private func start(_ scope: WorkspacePresenceScope) {
        let model = WorkspacePresenceSession(transport: transport, clock: clock)
        let entry = WorkspacePresenceObservation(session: model)
        sessions[scope] = entry
        let generation = generation
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.generation == generation && self.isCurrent() && self.sessions[scope]?.session === model
        }
        let token = accessToken
        let snapshots = model.snapshots()
        entry.snapshotTask = Task { [weak self] in
            for await participants in snapshots {
                guard let self, current(), !Task.isCancelled else { return }
                guard self.values[scope, default: []] != participants else { continue }
                self.values[scope] = participants
                self.publish(scope)
            }
        }
        entry.runTask = Task {
            await model.run(scope: scope, accessToken: {
                guard current() else { return nil }
                let credential = await token()
                return current() ? credential : nil
            }, isCurrent: current)
        }
    }

    private func publish(_ scope: WorkspacePresenceScope) {
        for continuation in continuations.values { continuation.yield(scope) }
    }
}
