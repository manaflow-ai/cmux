import ArgumentParser
import Darwin
import Foundation

struct CmuxCommand: ParsableCommand {
    @OptionGroup var globals: GlobalOptions

    static let configuration = CommandConfiguration(
        commandName: "cmux",
        abstract: String(
            localized: "cli.root.abstract",
            defaultValue: "Control cmux via Unix socket."
        ),
        subcommands: [
            CompleteCandidates.self,
            Completion.self,
            DumpCommandTree.self,
            WelcomeCommand.self,
            DocsCommand.self,
            SettingsCommand.self,
            ConfigCommand.self,
            ShortcutsCommand.self,
            VersionCommand.self,
            CapabilitiesCommand.self,
            PingCommand.self,
            IrohDiagnosticsCommand.self,
            HelpCommand.self,
            ReloadConfigCommand.self,
            FeedbackCommand.self,
            ThemesCommand.self,
            InternalFlagsCommand.self,
            SidebarFooterIconBalanceCommand.self,
            AuthCommand.self,
            LoginCommand.self,
            LogoutCommand.self,
            AIAccountsCommand.self,
            VMCommand.self,
            RemotesCommand.self,
            RemoteDaemonStatusCommand.self,
            ListWindowsCommand.self,
            CurrentWindowCommand.self,
            NewWindowCommand.self,
            FocusWindowCommand.self,
            CloseWindowCommand.self,
            FindWindowCommand.self,
            NextWindowCommand.self,
            PreviousWindowCommand.self,
            LastWindowCommand.self,
            RenameWindowCommand.self,
            ListWorkspacesCommand.self,
            NewWorkspaceCommand.self,
            CloseWorkspaceCommand.self,
            SelectWorkspaceCommand.self,
            CurrentWorkspaceCommand.self,
            RenameWorkspaceCommand.self,
            ReorderWorkspaceCommand.self,
            ReorderWorkspacesCommand.self,
            MoveWorkspaceToWindowCommand.self,
            WorkspaceCommand.self,
            WorkspaceActionCommand.self,
            WorkspaceGroupCommand.self,
            MoveTabToNewWorkspaceCommand.self,
            NewPaneCommand.self,
            NewSplitCommand.self,
            NewSurfaceCommand.self,
            CloseSurfaceCommand.self,
            MoveSurfaceCommand.self,
            SplitOffCommand.self,
            ReorderSurfaceCommand.self,
            FocusPaneCommand.self,
            FocusPanelCommand.self,
            ListPanesCommand.self,
            ListPaneSurfacesCommand.self,
            ListPanelsCommand.self,
            DragSurfaceToSplitCommand.self,
            SurfaceCommand.self,
            SurfaceHealthCommand.self,
            SurfaceResumeCommand.self,
            DetachTabCommand.self,
            TabActionCommand.self,
            RenameTabCommand.self,
            LastPaneCommand.self,
            RefreshSurfacesCommand.self,
            DebugTerminalsCommand.self,
            SidebarStateCommand.self,
            BrowserCommand.self,
            OpenBrowserCommand.self,
            NavigateCommand.self,
            BrowserBackLegacyCommand.self,
            BrowserForwardLegacyCommand.self,
            BrowserReloadLegacyCommand.self,
            BrowserStatusLegacyCommand.self,
            GetURLCommand.self,
            FocusWebviewLegacyCommand.self,
            WebviewFocusedLegacyCommand.self,
            DisableBrowserCommand.self,
            EnableBrowserCommand.self,
            CapturePaneCommand.self,
            ResizePaneCommand.self,
            PipePaneCommand.self,
            WaitForCommand.self,
            SwapPaneCommand.self,
            BreakPaneCommand.self,
            JoinPaneCommand.self,
            ClearHistoryCommand.self,
            SetHookCommand.self,
            PopupCommand.self,
            BindKeyCommand.self,
            UnbindKeyCommand.self,
            CopyModeCommand.self,
            SetBufferCommand.self,
            ListBuffersCommand.self,
            PasteBufferCommand.self,
            RespawnPaneCommand.self,
            DisplayMessageCommand.self,
            ReadScreenCommand.self,
            SendCommand.self,
            SendKeyCommand.self,
            SendPanelCommand.self,
            SendKeyPanelCommand.self,
            TmuxCompatCommand.self,
            HooksCommand.self,
            SetupHooksCommand.self,
            UninstallHooksCommand.self,
            ClaudeHookCommand.self,
            CodexHookCommand.self,
            FeedHookCommand.self,
            ClaudeTeamsCommand.self,
            CodexTeamsCommand.self,
            CodexCommand.self,
            OMOCommand.self,
            OMXCommand.self,
            OMCCommand.self,
            AgentHibernationCommand.self,
            CoderouterCommand.self,
            CodexTeamsWatchCommand.self,
            CodexTeamsAppServerSupervisorCommand.self,
            NotifyCommand.self,
            ListNotificationsCommand.self,
            DismissNotificationCommand.self,
            MarkNotificationReadCommand.self,
            OpenNotificationCommand.self,
            JumpToUnreadCommand.self,
            ClearNotificationsCommand.self,
            FeedCommand.self,
            EventsCommand.self,
            LogCommand.self,
            ListLogCommand.self,
            ClearLogCommand.self,
            SetStatusCommand.self,
            ListStatusCommand.self,
            ClearStatusCommand.self,
            SetProgressCommand.self,
            ClearProgressCommand.self,
            OpenCommand.self,
            DiffCommand.self,
            MarkdownCommand.self,
            MemoryCommand.self,
            TopCommand.self,
            TreeCommand.self,
            IdentifyCommand.self,
            TriggerFlashCommand.self,
            RestoreCommand.self,
            RestoreSessionCommand.self,
            RPCCommand.self,
            SimulatorCommand.self,
            IOSCommand.self,
            MobileCommand.self,
            SSHCommand.self,
            MoshCommand.self,
            MoshTmuxCommand.self,
            SSHTmuxCommand.self,
            SSHSessionListCommand.self,
            SSHSessionAttachCommand.self,
            SSHSessionCleanupCommand.self,
            SSHSessionEndCommand.self,
            SSHPTYAttachCommand.self,
            VMPtyAttachCommand.self,
            VMPtyConnectCommand.self,
            VMSSHAttachTopLevelCommand.self,
            TodoCommand.self,
            CommentsCommand.self,
            SidebarCommand.self,
            RightSidebarCommand.self,
            SetAppFocusCommand.self,
            SimulateAppActiveCommand.self,
            SimulateSidebarDragCommand.self,
            ProjectCommand.self,
            WindowNamespaceCommand.self,
            CanvasCommand.self,
            LayoutCommand.self,
        ]
    )

    /// Every command name and alias the facade owns. The router sends only these
    /// to ArgumentParser; everything else falls through to the legacy parser.
    /// Cached: building this walks every subcommand's `configuration`, which
    /// evaluates localized abstracts and (for `coderouter`) locates the app
    /// bundle, so recomputing it on every invocation is measurably slow.
    static let declaredCommandNames: Set<String> = {
        var names: Set<String> = []
        for subcommand in configuration.subcommands {
            let config = subcommand.configuration
            if let name = config.commandName { names.insert(name) }
            names.formUnion(config.aliases)
        }
        return names
    }()

    /// Commands implemented by the ArgumentParser facade itself rather than
    /// delegated back to the legacy command runner.
    static let facadeNativeCommandNames: Set<String> = [
        "__complete-candidates",
        "__dump-command-tree",
        "completion",
    ]

    /// Runs the facade while preserving the legacy CLI's exit-status contract
    /// for command-specific validation. ArgumentParser uses EX_USAGE (64) for
    /// `ValidationError`; cmux historically reports these selector errors as 2.
    static func runFacade() {
        do {
            var command = try parseAsRoot()
            try command.run()
        } catch let error as FacadeValidationError {
            CMUXCLIOutput.writeStandardError("Error: \(error.message)\n")
            CMUXCLIOutput.writeStandardError("\(usageString(for: error.command))\n")
            Darwin.exit(error.exitCode)
        } catch let error as CLIError {
            CMUXCLIOutput.writeStandardError("Error: \(error)\n")
            Darwin.exit(error.exitCode)
        } catch {
            exit(withError: error)
        }
    }
}

/// A validation failure whose diagnostic needs cmux's historical exit code.
/// Rendering and process termination stay at the facade boundary, not in a
/// command declaration. Legacy reports these selector errors via plain
/// `CLIError(message:)`, whose default exit code is 1.
struct FacadeValidationError: Error {
    let message: String
    let command: ParsableCommand.Type
    let exitCode: Int32 = 1
}
