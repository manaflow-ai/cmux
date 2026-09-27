import CmuxComputerUse

/// The presentation boundary for deliberate Settings and protected-tool requests.
///
/// The runtime owns setup progress and tool admission. Presenting a window never
/// grants access; the user still completes the existing permission/capture flow.
/// Ambient lifecycle/status updates have no presentation entry point here.
@MainActor
final class ComputerUseOnboardingCoordinator {
    typealias StartingPoint = ComputerUseOnboardingWindowController.StartingPoint
    typealias Presenter = @MainActor (StartingPoint) -> Void

    private let runtimeService: ComputerUseRuntimeService
    private let presenter: Presenter

    init(runtimeService: ComputerUseRuntimeService, presenter: @escaping Presenter) {
        self.runtimeService = runtimeService
        self.presenter = presenter
    }

    /// Handles the deliberate Settings permission/setup action. Every request
    /// reaches the existing presenter so a newly selected permission step is
    /// honored even while onboarding is visible.
    @discardableResult
    func requestFromSettings(startingAt startingPoint: StartingPoint) -> Bool {
        runtimeService.onboardingWasPresented()
        presenter(startingPoint)
        return true
    }

    /// Claims and presents first-use setup atomically on the main actor. A ready
    /// helper or an already claimed flow stays quiet, including after dismissal.
    /// Call only for authenticated, locally owned functional CUA requests.
    @discardableResult
    func requestFromToolInvocation() -> Bool {
        guard runtimeService.requestAutomaticOnboarding() else { return false }
        presenter(.overview)
        return true
    }
}
