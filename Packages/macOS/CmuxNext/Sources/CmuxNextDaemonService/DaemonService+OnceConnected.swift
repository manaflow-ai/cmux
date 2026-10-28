public import CmuxNextActions
public import CmuxNextDaemon

extension DaemonService {
    /// Whether commands reach the daemon now: a connection whose link is up. `connection`
    /// alone stays set while a dropped link retries (a Cloud VM paused after it connected),
    /// and is nil only until the first connect, so it misses a drop.
    public var isLive: Bool {
        guard connection != nil, case .connected = store.connectionState else { return false }
        return true
    }

    /// ``failure(_:_:)``, after waiting for this daemon to be live when `waits`. A person's close
    /// of a workspace of a machine that is not connected (a paused Cloud VM) waits for the machine
    /// to connect again instead of failing "not connected" and listing the row again. The wait
    /// ends when `present` turns false (the machine left the app: signed out, removed), and the
    /// command then fails "not connected". Driven by observation, never by polling (an
    /// ``ObservedCondition``, its re-reads visible tasks); a cancelled wait runs the command at
    /// once (it then fails).
    public func failureOnceConnected(_ label: String, waits: Bool, while present: @escaping @MainActor @Sendable () -> Bool,
                                     _ body: DaemonCommandBody) async -> ActionWorkFailure? {
        if waits {
            await ObservedCondition(owner: "DaemonService.onceConnected", .visible, on: mainWork).until {
                self.isLive || !present()
            }
        }
        return await failure(label, body)
    }
}
