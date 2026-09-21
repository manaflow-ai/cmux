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

    /// Presents setup after runtime admission claims an explicit first-use
    /// request. Runtime phase claiming remains the source of truth.
    @discardableResult
    func requestFromToolInvocation() -> Bool {
        presenter(.overview)
        return true
    }
}
