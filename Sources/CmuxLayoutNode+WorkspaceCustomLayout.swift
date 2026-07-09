import CmuxWorkspaces

/// Maps the app-target `cmux.json` layout Codable types onto the package value
/// image ``WorkspaceCustomLayoutNode`` that ``WorkspaceLayoutCoordinator`` walks.
///
/// The translation is faithful and deterministic: a `.pane` carries its surfaces
/// through, a `.split` carries its `splitOrientation`, its already-clamped
/// `clampedSplitPosition`, and its two children. The Codable types own the wire
/// format; this mapping runs once at the `applyCustomLayout` boundary so the
/// coordinator never imports the app target.
extension CmuxLayoutNode {
    var workspaceCustomLayoutNode: WorkspaceCustomLayoutNode {
        workspaceCustomLayoutNode(prependingSetupCommand: nil)
    }

    func workspaceCustomLayoutNode(prependingSetupCommand setupCommand: String?) -> WorkspaceCustomLayoutNode {
        var pendingSetupCommand = setupCommand
        return workspaceCustomLayoutNode(consumingSetupCommand: &pendingSetupCommand)
    }

    private func workspaceCustomLayoutNode(consumingSetupCommand setupCommand: inout String?) -> WorkspaceCustomLayoutNode {
        switch self {
        case .pane(let pane):
            return .pane(surfaces: pane.surfaces.map { $0.workspaceCustomSurface(consumingSetupCommand: &setupCommand) })
        case .split(let split):
            return .split(
                orientation: split.splitOrientation,
                clampedSplitPosition: split.clampedSplitPosition,
                children: split.children.map { $0.workspaceCustomLayoutNode(consumingSetupCommand: &setupCommand) }
            )
        }
    }
}

extension CmuxSurfaceDefinition {
    var workspaceCustomSurface: WorkspaceCustomSurface {
        var setupCommand: String?
        return workspaceCustomSurface(consumingSetupCommand: &setupCommand)
    }

    func workspaceCustomSurface(consumingSetupCommand setupCommand: inout String?) -> WorkspaceCustomSurface {
        var resolvedCommand = command
        if type == .terminal, let setup = setupCommand {
            resolvedCommand = [setup, command].compactMap { $0 }.joined(separator: "\n")
            setupCommand = nil
        }
        return WorkspaceCustomSurface(
            kind: type.workspaceCustomSurfaceKind,
            name: name,
            command: resolvedCommand,
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

extension CmuxWorkspaces.CmuxLayoutNode {
    var workspaceCustomLayoutNode: WorkspaceCustomLayoutNode {
        workspaceCustomLayoutNode(prependingSetupCommand: nil)
    }

    func workspaceCustomLayoutNode(prependingSetupCommand setupCommand: String?) -> WorkspaceCustomLayoutNode {
        var pendingSetupCommand = setupCommand
        return workspaceCustomLayoutNode(consumingSetupCommand: &pendingSetupCommand)
    }

    private func workspaceCustomLayoutNode(consumingSetupCommand setupCommand: inout String?) -> WorkspaceCustomLayoutNode {
        switch self {
        case .pane(let pane):
            return .pane(surfaces: pane.surfaces.map { $0.workspaceCustomSurface(consumingSetupCommand: &setupCommand) })
        case .split(let split):
            return .split(
                orientation: split.splitOrientation,
                clampedSplitPosition: split.clampedSplitPosition,
                children: split.children.map { $0.workspaceCustomLayoutNode(consumingSetupCommand: &setupCommand) }
            )
        }
    }
}

extension CmuxWorkspaces.CmuxSurfaceDefinition {
    var workspaceCustomSurface: WorkspaceCustomSurface {
        var setupCommand: String?
        return workspaceCustomSurface(consumingSetupCommand: &setupCommand)
    }

    func workspaceCustomSurface(consumingSetupCommand setupCommand: inout String?) -> WorkspaceCustomSurface {
        var resolvedCommand = command
        if type == .terminal, let setup = setupCommand {
            resolvedCommand = [setup, command].compactMap { $0 }.joined(separator: "\n")
            setupCommand = nil
        }
        return WorkspaceCustomSurface(
            kind: type.workspaceCustomSurfaceKind,
            name: name,
            command: resolvedCommand,
            cwd: cwd,
            env: env,
            url: url,
            focus: focus
        )
    }
}

extension CmuxWorkspaces.CmuxSurfaceType {
    var workspaceCustomSurfaceKind: WorkspaceCustomSurface.Kind {
        switch self {
        case .terminal: return .terminal
        case .browser: return .browser
        case .project: return .project
        }
    }
}
