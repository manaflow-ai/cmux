import CmuxNextComputerUse

/// Brings forward what a Computer Use session drives or where it started:
/// ``AppComputerUseFocus`` in the App, a fake in tests.
@MainActor
protocol ComputerUseFocusing: AnyObject {
    /// Activates the session's target app; false when it is not running.
    func raiseTarget(of session: ComputerUseLiveSession) -> Bool
    /// Reveals and focuses the terminal tab that started the session; false when no machine has it.
    func revealCallingTerminal(of session: ComputerUseLiveSession) -> Bool
}
