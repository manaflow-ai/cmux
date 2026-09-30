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
public enum CommandPaletteCloudCapabilityPolicy {
    /// Returns the Cloud capability for a built-in command ID. Unknown and
    /// user-configured actions remain shared unless they add their own gate.
    public static func capability(for commandId: String) -> CommandPaletteCloudCapability {
        if commandId.hasPrefix("palette.terminalOpenDirectory.") {
            return .localOnly
        }

        switch commandId {
        case "palette.cloud.fork",
             "palette.cloud.snapshot",
             "palette.cloud.restore",
             "palette.cloud.promoteTemplate",
             "palette.cloud.status",
             "palette.cloud.ports",
             "palette.cloud.tools",
             "palette.cloud.handoff":
            return .cloudOnly
        case "palette.newBrowserWorkspace",
             "palette.newAgentChat",
             "palette.newBrowserTab",
             "palette.newSimulatorPane",
             "palette.openFolder",
             "palette.openFolderInVSCodeInline",
             "palette.openWorkspacePullRequests",
             "palette.openDiffViewer",
             "palette.openDirectoryDiffViewer",
             "palette.findInDirectory",
             "palette.vscodeServeWebStop",
             "palette.vscodeServeWebRestart",
             "palette.browserSplitRight",
             "palette.browserSplitDown",
             "palette.terminalSplitBrowserRight",
             "palette.terminalSplitBrowserDown":
            return .localOnly
        default:
            return .shared
        }
    }

    /// Returns whether a command can be materialized for the supplied context.
    /// Cloud-only commands require the selected Cloud workspace; local-only
    /// commands are omitted while a Cloud workspace is selected.
    public static func allows(
        commandId: String,
        context: CommandPaletteContextSnapshot
    ) -> Bool {
        switch capability(for: commandId) {
        case .shared:
            return true
        case .cloudOnly:
            return context.bool(CommandPaletteContextKeys.workspaceIsCloud)
        case .localOnly:
            return !context.bool(CommandPaletteContextKeys.workspaceIsCloud)
        }
    }
}
