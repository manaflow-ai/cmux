public import CmuxNextActions
import CmuxNextCompat

extension DaemonService {
    /// ``failure(_:_:)``, after waiting for this daemon to connect when `waits`. A person's close of a
    /// workspace of a machine that is not connected (a paused Cloud VM) waits for the machine to
    /// connect again instead of failing "not connected" and listing the row again. The wait ends
    /// when `present` turns false (the machine left the app: signed out, removed), and the command
    /// then fails "not connected". Driven by observation, never by polling; a cancelled wait runs
    /// the command at once (it then fails).
    public func failureOnceConnected(_ label: String, waits: Bool, while present: @escaping @MainActor @Sendable () -> Bool,
                                     _ body: DaemonCommandBody) async -> ActionWorkFailure? {
        if waits { for await done in ObservationStream({ self.connection != nil || !present() }) where done { break } }
        return await failure(label, body)
    }
}
