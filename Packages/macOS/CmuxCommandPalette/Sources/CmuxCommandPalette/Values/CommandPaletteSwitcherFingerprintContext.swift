public import Foundation

/// Change-detection fingerprint input for one window's switcher contents.
public struct CommandPaletteSwitcherFingerprintContext: Sendable {
    /// Window id.
    public let windowId: UUID
    /// Optional window label.
    public let windowLabel: String?
    /// The window's selected workspace, when any.
    public let selectedWorkspaceId: UUID?
    /// The window's workspaces, in switcher order.
    public let workspaces: [CommandPaletteSwitcherFingerprintWorkspace]

    /// Creates a window fingerprint input.
    public init(
        windowId: UUID,
        windowLabel: String?,
        selectedWorkspaceId: UUID?,
        workspaces: [CommandPaletteSwitcherFingerprintWorkspace]
    ) {
        self.windowId = windowId
        self.windowLabel = windowLabel
        self.selectedWorkspaceId = selectedWorkspaceId
        self.workspaces = workspaces
    }

    /// Order-sensitive fingerprint over every window's switcher contents,
    /// used to detect when the switcher corpus must be rebuilt. Hash values
    /// are only compared within the current process.
    public static func fingerprint(
        windowContexts: [CommandPaletteSwitcherFingerprintContext]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(windowContexts.count)
        for context in windowContexts {
            hasher.combine(context.windowId)
            hasher.combine(context.windowLabel)
            hasher.combine(context.selectedWorkspaceId)
            hasher.combine(context.workspaces.count)
            for workspace in context.workspaces {
                hasher.combine(workspace.id)
                hasher.combine(workspace.displayName)
                workspace.metadata.combine(into: &hasher)
                hasher.combine(workspace.surfaces.count)
                for surface in workspace.surfaces {
                    hasher.combine(surface.id)
                    hasher.combine(surface.displayName)
                    hasher.combine(surface.kindLabel)
                    surface.metadata.combine(into: &hasher)
                }
            }
        }
        return hasher.finalize()
    }
}
