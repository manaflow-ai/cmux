/// Serializes the one trusted entrypoint for the Computer Use permission UI.
///
/// Workstream events are intentionally not an entrypoint. No agent-selected
/// tool, skill event, prompt, or helper status can call the presenter. Settings
/// calls the explicit `requestFromSettings` method instead.
@MainActor
final class ComputerUseOnboardingCoordinator {
    typealias StartingPoint = ComputerUseOnboardingWindowController.StartingPoint
    typealias Presenter = @MainActor (StartingPoint) -> Void

    private let presenter: Presenter

    init(presenter: @escaping Presenter) {
        self.presenter = presenter
    }

    /// Handles the deliberate Settings permission/setup action. Every request
    /// reaches the existing presenter so a newly selected permission step is
    /// honored even while onboarding is visible; agent events never call this.
    @discardableResult
    func requestFromSettings(startingAt startingPoint: StartingPoint) -> Bool {
        presenter(startingPoint)
        return true
    }
}
