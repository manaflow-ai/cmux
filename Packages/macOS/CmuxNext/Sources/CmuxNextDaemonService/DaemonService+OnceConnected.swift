public import CmuxNextActions
public import CmuxNextDaemon
import CmuxNextCompat

extension DaemonService {
    /// Whether commands reach the daemon now: a connection whose link is up. `connection`
    /// alone stays set while a dropped link retries (a Cloud VM paused after it connected),
    /// and is nil only until the first connect, so it misses a drop.
    public var isLive: Bool {
        guard connection != nil, case .connected = store.connectionState else { return false }
        return true
    }

    /// Waits for a live snapshot and a connection that can actually accept requests. The observed
    /// lifecycle can trail the connection actor, so arm its changes before checking the actor.
    public func waitForReadySnapshot() async throws {
        let (_, changes) = ObservationStream.current {
            _ = self.connection
            _ = self.store.connectionState
            _ = self.store.isLoaded
        }
        if isLive, store.isLoaded, await connection?.isReady == true { return }
        for await _ in changes {
            try Task.checkCancellation()
            if isLive, store.isLoaded, await connection?.isReady == true { return }
        }
        throw CancellationError()
    }

    /// ``failure(_:_:)``, after waiting for this daemon to be live when `waits`. A person's close
    /// of a workspace of a machine that is not connected (a paused Cloud VM) waits for the machine
    /// to connect again instead of failing "not connected" and listing the row again. The wait
    /// ends when `present` turns false (the machine left the app: signed out, removed), and the
    /// command then fails "not connected". Driven by observation, never by polling; a cancelled
    /// wait runs the command at once (it then fails).
    public func failureOnceConnected(_ label: String, waits: Bool, while present: @escaping @MainActor @Sendable () -> Bool,
                                     _ body: DaemonCommandBody) async -> ActionWorkFailure? {
        if waits { for await done in ObservationStream({ self.isLive || !present() }) where done { break } }
        return await failure(label, body)
    }
}
