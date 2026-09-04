/// Serializes the one trusted entrypoint for the Computer Use permission UI.
///
/// Workstream events are intentionally not an entrypoint. No agent-selected
/// tool, skill event, prompt, or helper status can call the presenter. Settings
/// calls the explicit `requestFromSettings` method instead.
@MainActor
final class ComputerUseOnboardingCoordinator {
    typealias StartingPoint = ComputerUseOnboardingWindowController.StartingPoint
    typealias Presenter = @MainActor (StartingPoint) -> Void
    typealias Visibility = @MainActor () -> Bool

    private let presenter: Presenter
    private let isVisible: Visibility

    init(
        presenter: @escaping Presenter,
        isVisible: @escaping Visibility = { false }
    ) {
        self.presenter = presenter
        self.isVisible = isVisible
    }

    /// Handles the deliberate Settings permission/setup action. Main-actor
    /// serialization plus the visibility check coalesces repeated clicks while
    /// the existing onboarding window or companion is on screen.
    @discardableResult
    func requestFromSettings(startingAt startingPoint: StartingPoint) -> Bool {
        guard !isVisible() else { return false }
        presenter(startingPoint)
        return true
    }
}
