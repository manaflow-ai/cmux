import Foundation

/// Resolves the per-host origin color (beta) that names a remote workspace's server, for the sidebar
/// and the palette switcher, so both show a server in the same color. The UI builds one with the
/// app's host color registry and the setting's current value.
@MainActor
struct RemoteHostOriginColor {
    /// Whether Remote host colors is on.
    let enabled: Bool
    /// Where hosts get their colors. Tests pass their own.
    let registry: RemoteHostColorRegistry?

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

    /// The host's color, or nil while the setting is off or the workspace has no host.
    func colorHex(for workspace: Workspace, mirrorDestinations: [UUID: String]?) -> String? {
        guard enabled, let destination = Self.destination(for: workspace, mirrorDestinations: mirrorDestinations) else {
            return nil
        }
        return registry?.colorHex(for: destination)
    }

    /// The shade for a workspace's palette switcher rows.
    func switcherTintHex(for workspace: Workspace, mirrorDestinations: [UUID: String]?) -> String? {
        switcherTintHex(
            customColor: workspace.customColor,
            hostColorHex: colorHex(for: workspace, mirrorDestinations: mirrorDestinations)
        )
    }

    /// The shade for a remote workspace's switcher rows: its manual color when it has one, as in the
    /// sidebar, otherwise its host's color. Nil for a local workspace and while the setting is off.
    func switcherTintHex(customColor: String?, hostColorHex: String?) -> String? {
        guard let hostColorHex else { return nil }
        return customColor ?? hostColorHex
    }
}
