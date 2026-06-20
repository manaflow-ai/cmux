import CmuxWorkspaces

/// Maps the app-target `cmux.json` layout Codable types onto the package value
/// image ``WorkspaceCustomLayoutNode`` that ``WorkspaceLayoutCoordinator`` walks.
///
/// The translation is faithful and deterministic: a `.pane` carries its surfaces
/// through, a `.split` carries its `splitOrientation`, its already-clamped
/// `clampedSplitPosition`, and its two children. The app-target Codable types own
/// the wire format; this mapping runs once at the `applyCustomLayout` boundary so
/// the coordinator never imports the app target.
extension CmuxLayoutNode {
    var workspaceCustomLayoutNode: WorkspaceCustomLayoutNode {
        switch self {
        case .pane(let pane):
            return .pane(surfaces: pane.surfaces.map(\.workspaceCustomSurface))
        case .split(let split):
            return .split(
                orientation: split.splitOrientation,
                clampedSplitPosition: split.clampedSplitPosition,
                children: split.children.map(\.workspaceCustomLayoutNode)
            )
        }
    }
}

extension CmuxSurfaceDefinition {
    var workspaceCustomSurface: WorkspaceCustomSurface {
        WorkspaceCustomSurface(
            kind: type.workspaceCustomSurfaceKind,
            name: name,
            command: command,
            cwd: cwd,
            env: env,
            url: url,
            focus: focus
        )
    }
}

extension CmuxSurfaceType {
    var workspaceCustomSurfaceKind: WorkspaceCustomSurface.Kind {
        switch self {
        case .terminal: return .terminal
        case .browser: return .browser
        case .project: return .project
        }
    }
}
