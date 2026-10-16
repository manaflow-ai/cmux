import Foundation

/// Describes where a command-palette action can run relative to a managed
/// Cloud workspace.
public enum CommandPaletteCloudCapability: Equatable, Sendable {
    /// The action is valid for both local and Cloud workspaces.
    case shared
    /// The action needs a selected Cloud workspace and its current VM.
    case cloudOnly
    /// The action creates or reads a resource on this Mac's local filesystem,
    /// browser stack, or simulator and cannot target a Cloud workspace.
    case localOnly
}

/// Classifies built-in command-palette actions before they are materialized.
/// The app owns command contributions and handlers; this package owns the
/// pure capability decision so it can be tested without app singletons.
public struct CommandPaletteCloudCapabilityPolicy: Sendable {
    /// Creates the stateless capability policy.
    public init() {}

    /// Returns the Cloud capability for a built-in command ID. Unknown and
    /// user-configured actions remain shared unless they add their own gate.
    public func capability(for commandId: String) -> CommandPaletteCloudCapability {
        if commandId.hasPrefix("palette.terminalOpenDirectory.") {
            return .localOnly
        }

        switch commandId {
        case "palette.cloud.fork",
             "palette.cloud.snapshot",
             "palette.cloud.promoteTemplate",
             "palette.cloud.status",
             "palette.cloud.ports",
             "palette.cloud.tools",
             "palette.cloud.handoff":
            return .cloudOnly
        case "palette.newBrowserWorkspace",
             "palette.newAgentChat",
             "palette.newSimulatorPane",
             "palette.openFolder",
             "palette.openFolderInVSCodeInline",
             "palette.openWorkspacePullRequests",
             "palette.openDiffViewer",
             "palette.openDirectoryDiffViewer",
             "palette.findInDirectory",
             "palette.vscodeServeWebStop",
             "palette.vscodeServeWebRestart",
             "palette.terminalAttachTextBoxFile",
             "palette.openTerminalChatView":
            return .localOnly
        default:
            return .shared
        }
    }

    /// Returns whether a command can be materialized for the supplied context.
    /// Cloud-only commands require the selected Cloud workspace; local-only
    /// commands are omitted while a Cloud workspace is selected.
    public func allows(
        commandId: String,
        context: CommandPaletteContextSnapshot
    ) -> Bool {
        switch capability(for: commandId) {
        case .shared:
            // Restore creates a new VM from a supplied snapshot and remains
            // available from a local workspace, but a selected Cloud VM can
            // advertise that the provider does not support restore.
            guard commandId == "palette.cloud.restore",
                  context.bool(CommandPaletteContextKeys.workspaceIsCloud),
                  context.bool(CommandPaletteContextKeys.cloudVMCapabilitiesKnown) else {
                return true
            }
            return context.bool(CommandPaletteContextKeys.cloudVMSupportsRestore)
        case .cloudOnly:
            guard context.bool(CommandPaletteContextKeys.workspaceIsCloud) else {
                return false
            }
            guard context.bool(CommandPaletteContextKeys.cloudVMCapabilitiesKnown) else {
                return true
            }
            switch commandId {
            case "palette.cloud.fork":
                return context.bool(CommandPaletteContextKeys.cloudVMSupportsFork)
            case "palette.cloud.snapshot", "palette.cloud.promoteTemplate":
                return context.bool(CommandPaletteContextKeys.cloudVMSupportsSnapshot)
            case "palette.cloud.restore":
                return context.bool(CommandPaletteContextKeys.cloudVMSupportsRestore)
            case "palette.cloud.ports":
                return context.bool(CommandPaletteContextKeys.cloudVMSupportsPorts)
            case "palette.cloud.tools":
                return context.bool(CommandPaletteContextKeys.cloudVMSupportsExec)
            default:
                return true
            }
        case .localOnly:
            return !context.bool(CommandPaletteContextKeys.workspaceIsCloud)
        }
    }
}
