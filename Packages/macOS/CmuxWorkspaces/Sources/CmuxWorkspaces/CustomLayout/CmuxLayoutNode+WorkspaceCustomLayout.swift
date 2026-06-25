/// Maps the `cmux.json` layout wire types onto the package value image
/// ``WorkspaceCustomLayoutNode`` that ``WorkspaceLayoutCoordinator`` walks.
///
/// The translation is faithful and deterministic: a `.pane` carries its surfaces
/// through, a `.split` carries its `splitOrientation`, its already-clamped
/// `clampedSplitPosition`, and its two children. ``CmuxLayoutNode`` owns the wire
/// format; this mapping runs once at the `applyCustomLayout` boundary so the
/// coordinator orchestrates only the already-resolved value image.
extension CmuxLayoutNode {
    /// The already-resolved ``WorkspaceCustomLayoutNode`` image of this wire node.
    public var workspaceCustomLayoutNode: WorkspaceCustomLayoutNode {
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
    /// The ``WorkspaceCustomSurface`` image of this wire surface.
    public var workspaceCustomSurface: WorkspaceCustomSurface {
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
    /// The ``WorkspaceCustomSurface/Kind`` image of this wire surface type.
    public var workspaceCustomSurfaceKind: WorkspaceCustomSurface.Kind {
        switch self {
        case .terminal: return .terminal
        case .browser: return .browser
        case .project: return .project
        }
    }
}
