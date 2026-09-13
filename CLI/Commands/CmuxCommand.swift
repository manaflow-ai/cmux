import ArgumentParser
import Darwin
import Foundation

struct CmuxCommand: AsyncParsableCommand {
    @OptionGroup var globals: GlobalOptions

    /// The flag spelling of `cmux guide`. `--skill` is not a declared command
    /// name, so the router always hands `cmux --skill` to the legacy parser;
    /// this declaration only lets completion offer it.
    @Flag(name: .customLong("skill")) var skill = false

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
            GuideCommand.self,
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
            ReadSelectionCommand.self,
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
            VMAgentShortFormCommand.self,
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
            ForkCommand.self,
            RestoreSessionCommand.self,
            SessionsCommand.self,
            RPCCommand.self,
            SimulatorCommand.self,
            IOSCommand.self,
            MobileCommand.self,
            SSHCommand.self,
            MoshCommand.self,
            MoshTmuxCommand.self,
            SSHTmuxCommand.self,
            LocalTmuxCommand.self,
            TmuxAliasCommand.self,
            SSHSessionListCommand.self,
            SSHSessionAttachCommand.self,
            SSHSessionCleanupCommand.self,
            SSHSessionEndCommand.self,
            SSHPTYAttachCommand.self,
            VMPtyAttachCommand.self,
            VMPtyConnectCommand.self,
            VMTuiConnectCommand.self,
            VMTuiApproveCommand.self,
            VMSSHAttachTopLevelCommand.self,
            AutomationCommand.self,
            VPNCommand.self,
            SudoCommand.self,
            VaultCommand.self,
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

    /// Every command name and alias the facade declares, which is the set typo
    /// suggestions draw from. The router does not consult it: only
    /// `facadeNativeCommandNames` reach ArgumentParser.
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
    /// delegated back to the legacy command runner. These are the only commands
    /// the router hands to ArgumentParser.
    static let facadeNativeCommandNames: Set<String> = [
        "__complete-candidates",
        "__dump-command-tree",
        "completion",
    ]

    /// Runs a facade-native command. A `CLIError` keeps its own exit code rather
    /// than ArgumentParser's EX_USAGE (64), matching the legacy CLI.
    static func runFacade() async {
        do {
            var command = try parseAsRoot()
            // `parseAsRoot()` erases to `ParsableCommand`, so the async path has to
            // be recovered by cast. Delegating commands are async because they call
            // `CMUXCLI.run()`; the facade-native ones (`completion`, the candidate
            // and tree dumps) stay synchronous.
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as CLIError {
            CMUXCLIOutput.writeStandardError("Error: \(error)\n")
            Darwin.exit(error.exitCode)
        } catch {
            exit(withError: error)
        }
    }
}
