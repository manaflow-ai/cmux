/// The outcome of asking the Mac to sleep.
///
/// A sleep request usually drops the connection as the Mac sleeps, so a
/// connection error is not treated as a failure; only an explicit RPC error
/// such as missing Automation permission is `refused`.
public enum MobileMacSleepResult: Sendable, Equatable {
    /// The Mac acknowledged the request, or the connection dropped as it slept.
    case requested

    /// The Mac explicitly refused, most often because Automation access is missing.
    case refused

    /// The request could not be delivered because the Mac was unreachable or auth failed.
    case failed
}
