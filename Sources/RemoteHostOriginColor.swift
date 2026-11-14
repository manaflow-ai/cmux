import Foundation

/// The per-host origin color (beta) that names a remote workspace's server, shared by the sidebar
/// and the palette switcher so both show a server in the same color.
@MainActor
enum RemoteHostOriginColor {
    /// The remote destination a workspace comes from, or nil for a local workspace or a mirror whose
    /// host has not resolved yet. Mirror workspaces carry their host only through the session mirror,
    /// so callers pass `mirrorDestinations`, gathered once for a whole refresh.
    static func destination(for workspace: Workspace, mirrorDestinations: [UUID: String]?) -> String? {
        var destination = workspace.remoteConfiguration?.destination
        if destination == nil, workspace.isRemoteTmuxMirror {
            destination = mirrorDestinations?[workspace.id]
        }
        guard let destination, !destination.isEmpty else { return nil }
        return destination
    }

    /// The host's color, or nil while the flag is off or the workspace has no host.
    static func colorHex(
        for workspace: Workspace,
        mirrorDestinations: [UUID: String]?,
        enabled: Bool,
        registry: RemoteHostColorRegistry?
    ) -> String? {
        guard enabled, let destination = destination(for: workspace, mirrorDestinations: mirrorDestinations) else {
            return nil
        }
        return registry?.colorHex(for: destination)
    }

    /// Mirror hosts by workspace id, or nil while the flag is off.
    static func mirrorDestinations(enabled: Bool) -> [UUID: String]? {
        guard enabled else { return nil }
        return AppDelegate.shared?.remoteTmuxController.hostDestinationsByWorkspaceId()
    }

    /// The shade for a workspace's palette switcher rows, from the app's host colors.
    static func switcherTintHex(for workspace: Workspace, mirrorDestinations: [UUID: String]?, enabled: Bool) -> String? {
        let hostColorHex = colorHex(
            for: workspace,
            mirrorDestinations: mirrorDestinations,
            enabled: enabled,
            registry: AppDelegate.shared?.remoteTmuxController.hostColorRegistry
        )
        return switcherTintHex(customColor: workspace.customColor, hostColorHex: hostColorHex)
    }

    /// The shade for a remote workspace's switcher rows: its manual color when it has one, as in the
    /// sidebar, otherwise its host's color. Nil for a local workspace and while the flag is off.
    static func switcherTintHex(customColor: String?, hostColorHex: String?) -> String? {
        guard let hostColorHex else { return nil }
        return customColor ?? hostColorHex
    }
}
