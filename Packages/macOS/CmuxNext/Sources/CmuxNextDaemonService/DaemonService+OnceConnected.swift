public import CmuxNextActions
import CmuxNextCompat

extension DaemonService {
    /// ``failure(_:_:)``, after waiting for this daemon to connect when `waits`. A person's close of a
    /// workspace of a machine that is not connected (a paused Cloud VM) waits for the machine to
    /// connect again instead of failing "not connected" and listing the row again. Driven by the
    /// connection itself, never by polling; a cancelled wait runs the command at once (it then fails).
    public func failureOnceConnected(_ label: String, waits: Bool, _ body: DaemonCommandBody) async -> ActionWorkFailure? {
        if waits { for await ready in ObservationStream({ self.connection != nil }) where ready { break } }
        return await failure(label, body)
    }
}
