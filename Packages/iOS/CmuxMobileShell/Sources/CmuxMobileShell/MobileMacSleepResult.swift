/// The outcome of asking the Mac to sleep.
///
/// A sleep request usually drops the connection as the Mac sleeps, so a
/// connection-close error after sending is not treated as a failure. Timeouts
/// and other delivery failures are reported as ``failed``.
public enum MobileMacSleepResult: Sendable, Equatable {
    /// The Mac acknowledged the request, or the connection dropped as it slept.
    case requested

    /// The Mac explicitly refused, most often because Automation access is missing.
    case refused

    /// The request could not be delivered because the Mac was unreachable or auth failed.
    case failed
}
