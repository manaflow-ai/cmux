import CmuxNextCompat
public import CmuxNextDaemon

/// The `credential` family's registration for each local daemon connection (#65793): one registration per
/// connection epoch, started when that connection is up and cancelled when the epoch changes, so a registration
/// that a launch's daemon handoff cut short never stays the last word for the next connection.
@MainActor
public final class CloudCredentialRegistration {
    private var epoch: Int?
    private var running: Task<Void, Never>?
    /// The epoch the running (or finished) registration belongs to.
    private var registeredEpoch: Int?

    public init() {}

    /// Registers `provider` on every connection of `store` until the calling task is cancelled. The epoch rides
    /// with the state: a drop and reconnect while a registration was in flight brings back an equal `.connected`,
    /// which alone would not wake the loop again.
    public static func follow(_ store: DaemonStore, connection: @escaping @MainActor @Sendable () -> DaemonConnection?,
                              provider: CloudCredentialProvider) async {
        await follow(store) {
            guard let connection = connection() else { return }
            provider.stop()
            let allowed = await connection.userOriginAllowed
            _ = await CloudCredentialProvider.register(userOriginAllowed: allowed) { try await connection.request($0) }
        }
    }

    /// Runs `register` once per connected epoch of `store` (the previous epoch's run cancelled) until the calling task is cancelled.
    static func follow(_ store: DaemonStore, register: @escaping @MainActor @Sendable () async -> Void) async {
        let registration = CloudCredentialRegistration()
        defer { registration.cancel() }
        for await (state, epoch) in ObservationStream({ (store.connectionState, store.connectionEpoch) }) {
            let connected = if case .connected = state { true } else { false }
            registration.connectionChanged(epoch: epoch, connected: connected, register: register)
        }
    }

    /// A connection change: another epoch cancels the registration in flight; a connected epoch with none starts `register`.
    public func connectionChanged(epoch: Int, connected: Bool, register: @escaping @MainActor @Sendable () async -> Void) {
        if epoch != self.epoch {
            running?.cancel()
            running = nil
            registeredEpoch = nil
            self.epoch = epoch
        }
        guard connected, registeredEpoch != epoch else { return }
        registeredEpoch = epoch
        // task-owner: this epoch's registration with its retries; the next epoch or cancel() cancels it
        running = Task { await register() }
    }

    public func cancel() {
        running?.cancel()
        running = nil
    }
}
