/// Why a look at the screen found no frame for a reason that can pass (``ChiefScreenShare`` waits it out).
public enum ChiefScreenCaptureInterruption: Error, Sendable, Equatable {
    /// The capture process (the cmux Computer Use helper) is not running now: starting, or relaunching
    /// after the person granted Screen Recording ("Quit & Reopen").
    case unavailable
    /// Screen Recording is not allowed for the capture process.
    case notAllowed
}
