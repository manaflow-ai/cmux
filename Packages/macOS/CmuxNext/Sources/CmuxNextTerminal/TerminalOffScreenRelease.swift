public import CmuxNextWakeups

/// The one-shot deadline of ``TerminalOffScreenRelease``: a `background` ``MainDeadline`` in the app
/// (``TerminalGPUResidency/makeOffScreenDeadline()``), a manual one in tests.
@MainActor
public protocol TerminalOffScreenDeadline: AnyObject {
    /// Runs `action` once after `delay`, replacing a pending deadline.
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void)
    /// Drops the pending deadline.
    func cancel()
}

extension MainDeadline: TerminalOffScreenDeadline {}

/// When a shown surface lets its GPU memory go because its window stays off screen (p07-memory-097).
///
/// The window going off screen (its occlusion notice or its ``WindowOcclusionFamily`` flip, which
/// re-apply the surface's occlusion) arms one deadline of ``WindowDrawPolicy/offScreenGPUReleaseDelay``;
/// the window coming back cancels it. Once it fired, the paused surface counts as away
/// (``TerminalGPUResidencyGate``) until it is in a window on screen again: hiding or parking it in the
/// off-screen window (a scripted tab or workspace switch) keeps it released, and the show makes it
/// resident before Ghostty draws. Nothing polls the window. Without a deadline (no GPU release seam)
/// nothing is armed.
struct TerminalOffScreenRelease {
    let deadline: (any TerminalOffScreenDeadline)?
    /// A deadline is pending.
    private(set) var isArmed = false
    /// The window stayed off screen for the delay and the surface has not been in a window on screen since.
    private(set) var isDue = false

    init(deadline: (any TerminalOffScreenDeadline)?) {
        self.deadline = deadline
    }

    /// Follows the surface: shown in an off-screen window arms the deadline once; in a window on screen
    /// cancels it and ends the release. Anything else (hidden, parked, out of every window) changes nothing.
    ///
    /// - Parameters:
    ///   - shownOffScreen: The surface is shown in a window that is off screen.
    ///   - windowOnScreen: The surface is in a window that is on screen (``SurfaceDrawInputs/windowOnScreen``).
    /// - Returns: The deadline to schedule (the caller schedules it after this access ends), or nil.
    mutating func follow(shownOffScreen: Bool, windowOnScreen: Bool) -> (any TerminalOffScreenDeadline)? {
        if shownOffScreen {
            guard let deadline, !isArmed, !isDue else { return nil }
            isArmed = true
            return deadline
        }
        guard windowOnScreen else { return nil }
        if isArmed { deadline?.cancel() }
        isArmed = false
        isDue = false
        return nil
    }

    /// The deadline fired. True when it was still armed: the caller applies the occlusion again.
    mutating func delayPassed() -> Bool {
        guard isArmed else { return false }
        isArmed = false
        isDue = true
        return true
    }
}
