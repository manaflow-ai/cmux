/// The outcome of asking the Mac to sleep.
///
/// Only an acknowledged request is ``requested``. Timeouts, connection closes,
/// and other delivery failures are reported as ``failed``.
public enum MobileMacSleepResult: Sendable, Equatable {
    /// The Mac acknowledged the request.
    case requested

    /// The Mac explicitly refused, most often because Automation access is missing.
    case refused

    /// The request could not be delivered because the Mac was unreachable or auth failed.
    case failed
}
