@testable import CmuxControlSocket

extension ControlWorkspaceContext {
    func controlWorkspaceFontSizeStrings() -> ControlWorkspaceFontSizeStrings {
        ControlWorkspaceFontSizeStrings(
            invalidParams: "Invalid workspace font-size parameters",
            unavailable: "Workspace font-size unavailable",
            notFound: "Workspace not found",
            rejected: "Workspace font-size request rejected"
        )
    }

    func controlWorkspaceFontSize(
        routing: ControlRoutingSelectors,
        action: ControlWorkspaceFontSizeAction
    ) -> ControlWorkspaceFontSizeResolution {
        .unavailable
    }
}
