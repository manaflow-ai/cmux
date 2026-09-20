import AppKit

extension AppDelegate {
    /// A hook may show setup only for a terminal this app still owns locally.
    func ownsLocalComputerUseSurface(_ surfaceID: UUID, workspaceID: UUID?) -> Bool {
        guard let workspaceID,
              let manager = tabManagerFor(tabId: workspaceID),
              let workspace = manager.workspacesById[workspaceID],
              !workspace.isRemoteWorkspace,
              let target = workspace.surfaceOwnershipTarget(for: surfaceID),
              target.panel is TerminalPanel else {
            return false
        }
        return true
    }

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
