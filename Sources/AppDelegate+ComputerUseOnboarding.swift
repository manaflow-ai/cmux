import AppKit

extension AppDelegate {
    /// Presents Computer Use onboarding for command-palette and Settings
    /// entrypoints. The coordinator is the single owner of the window and
    /// permission flow, while this guard keeps early app lifecycle calls safe.
    @discardableResult
    func presentComputerUseOnboarding(
        startingAt startingPoint: ComputerUseOnboardingWindowController.StartingPoint = .overview
    ) -> Bool {
        guard CmuxFeatureFlags.shared.isComputerUseUXEnabled,
              computerUseRuntimeService != nil else {
            return false
        }
        return computerUseUXCoordinator.presentOnboardingFromSettings(
            startingAt: startingPoint
        )
    }
}
