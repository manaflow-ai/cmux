import Foundation

/// Labels shared by the workspace setup presentation and its App wiring.
public enum CloudWorkspaceSetupLocalization {
    /// The destination label when the account has no selected team.
    public nonisolated static let personalAccountTitle = String(localized: "cloud.workspaceSetup.personalAccount", defaultValue: "Personal account", table: "Cloud", bundle: .module)
}
