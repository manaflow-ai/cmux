/// Serializes Settings and first-use requests for the Computer Use permission UI.
///
/// The runtime owns setup progress and tool admission. Presenting a window never
/// grants access; the user still completes the existing permission/capture flow.
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
    /// honored even while onboarding is visible.
    @discardableResult
    func requestFromSettings(startingAt startingPoint: StartingPoint) -> Bool {
        presenter(startingPoint)
        return true
    }

    /// Called after the host matches a functional tool to an owned terminal.
    /// Claim presentation synchronously so retries and dismissal
    /// cannot repeatedly raise the window; Settings can always resume the flow.
    @discardableResult
    func requestFromToolInvocation(onboarding: ComputerUseOnboardingStore) -> Bool {
        if case .disabled(onboardingComplete: false) = onboarding.phase {
            onboarding.apply(.setEnabled(true))
        }
        guard onboarding.phase == .onboardingRequired else { return false }
        onboarding.apply(.onboardingPresented)
        presenter(.overview)
        return true
    }
}
