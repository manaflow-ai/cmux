import ArgumentParser
import Foundation

extension CMUXCLI {
    static let argumentParserInventoryCommand = "__argument-parser-inventory"

    protocol CLICommandName: CaseIterable, ExpressibleByArgument, RawRepresentable where RawValue == String {}

    struct CommandNameArguments<Command: CLICommandName>: ParsableArguments {
        @Argument var command: Command
    }

    struct CommandInventoryArguments: ParsableArguments {
        @Flag(name: .long, help: "Print JSON inventory.")
        var json = false

        @Flag(name: .long, help: "Verify every inventory token parses through ArgumentParser.")
        var verify = false
    }

    enum TopLevelCommandName: String, CLICommandName {
        case help
        case version
        case welcome
        case docs
        case settings
        case shortcuts
        case open
        case restoreSession = "restore-session"
        case feedback
        case feed
        case hooks
        case themes
        case claudeTeams = "claude-teams"
        case omo
        case omx
        case omc
        case codex
        case ping
        case capabilities
        case auth
        case vm
        case cloud
        case rpc
        case identify
        case listWindows = "list-windows"
        case currentWindow = "current-window"
        case newWindow = "new-window"
        case focusWindow = "focus-window"
        case closeWindow = "close-window"
        case moveWorkspaceToWindow = "move-workspace-to-window"
        case reorderWorkspace = "reorder-workspace"
        case workspaceAction = "workspace-action"
        case listWorkspaces = "list-workspaces"
        case newWorkspace = "new-workspace"
        case ssh
        case remoteDaemonStatus = "remote-daemon-status"
        case newSplit = "new-split"
        case listPanes = "list-panes"
        case listPaneSurfaces = "list-pane-surfaces"
        case tree
        case top
        case focusPane = "focus-pane"
        case newPane = "new-pane"
        case newSurface = "new-surface"
        case closeSurface = "close-surface"
        case moveSurface = "move-surface"
        case reorderSurface = "reorder-surface"
        case tabAction = "tab-action"
        case moveTabToNewWorkspace = "move-tab-to-new-workspace"
        case detachTab = "detach-tab"
        case renameTab = "rename-tab"
        case dragSurfaceToSplit = "drag-surface-to-split"
        case refreshSurfaces = "refresh-surfaces"
        case reloadConfig = "reload-config"
        case surfaceHealth = "surface-health"
        case debugTerminals = "debug-terminals"
        case triggerFlash = "trigger-flash"
        case listPanels = "list-panels"
        case focusPanel = "focus-panel"
        case closeWorkspace = "close-workspace"
        case selectWorkspace = "select-workspace"
        case renameWorkspace = "rename-workspace"
        case renameWindow = "rename-window"
        case currentWorkspace = "current-workspace"
        case readScreen = "read-screen"
        case send
        case sendKey = "send-key"
        case sendPanel = "send-panel"
        case sendKeyPanel = "send-key-panel"
        case notify
        case listNotifications = "list-notifications"
        case clearNotifications = "clear-notifications"
        case setStatus = "set-status"
        case clearStatus = "clear-status"
        case listStatus = "list-status"
        case setProgress = "set-progress"
        case clearProgress = "clear-progress"
        case log
        case clearLog = "clear-log"
        case listLog = "list-log"
        case sidebarState = "sidebar-state"
        case claudeHook = "claude-hook"
        case setAppFocus = "set-app-focus"
        case simulateAppActive = "simulate-app-active"
        case browser
        case disableBrowser = "disable-browser"
        case enableBrowser = "enable-browser"
        case browserStatus = "browser-status"
        case openBrowser = "open-browser"
        case navigate
        case browserBack = "browser-back"
        case browserForward = "browser-forward"
        case browserReload = "browser-reload"
        case getURL = "get-url"
        case focusWebview = "focus-webview"
        case isWebviewFocused = "is-webview-focused"
        case markdown
        case vmPtyAttach = "vm-pty-attach"
        case vmSSHAttach = "vm-ssh-attach"
        case vmPtyConnect = "vm-pty-connect"
        case sshSessionEnd = "ssh-session-end"
        case tmuxCompat = "__tmux-compat"
        case capturePane = "capture-pane"
        case resizePane = "resize-pane"
        case pipePane = "pipe-pane"
        case waitFor = "wait-for"
        case swapPane = "swap-pane"
        case breakPane = "break-pane"
        case joinPane = "join-pane"
        case lastWindow = "last-window"
        case lastPane = "last-pane"
        case nextWindow = "next-window"
        case previousWindow = "previous-window"
        case findWindow = "find-window"
        case clearHistory = "clear-history"
        case setHook = "set-hook"
        case popup
        case bindKey = "bind-key"
        case unbindKey = "unbind-key"
        case copyMode = "copy-mode"
        case setBuffer = "set-buffer"
        case pasteBuffer = "paste-buffer"
        case listBuffers = "list-buffers"
        case respawnPane = "respawn-pane"
        case displayMessage = "display-message"
    }

    enum AgentInstallerSubcommandName: String, CLICommandName {
        case installHooks = "install-hooks"
        case uninstallHooks = "uninstall-hooks"
    }

    enum AuthSubcommandName: String, CLICommandName {
        case status
        case login
        case logout
    }

    enum VMSubcommandName: String, CLICommandName {
        case ls
        case list
        case new
        case create
        case shell
        case attach
        case rm
        case destroy
        case delete
        case ssh
        case sshInfo = "ssh-info"
        case sshAttach = "ssh-attach"
        case exec
    }

    enum FeedSubcommandName: String, CLICommandName {
        case clear
        case tui
        case help
    }

    enum DocsSubcommandName: String, CLICommandName {
        case settings
        case shortcuts
        case api
        case browser
        case agents
    }

    enum SettingsSubcommandName: String, CLICommandName {
        case open
        case path
        case docs
    }

    enum HooksTargetName: String, CLICommandName {
        case setup
        case uninstall
        case feed
        case claude
        case codex
        case opencode
        case cursor
        case gemini
        case copilot
        case codebuddy
        case factory
        case qoder
    }

    enum HooksAgentActionName: String, CLICommandName {
        case install
        case uninstall
    }

    enum ThemeSubcommandName: String, CLICommandName {
        case list
        case set
        case clear
    }

    enum MarkdownSubcommandName: String, CLICommandName {
        case open
    }

    enum TopLevelTmuxCommandName: String, CLICommandName {
        case capturePane = "capture-pane"
        case resizePane = "resize-pane"
        case pipePane = "pipe-pane"
        case waitFor = "wait-for"
        case swapPane = "swap-pane"
        case breakPane = "break-pane"
        case joinPane = "join-pane"
        case lastWindow = "last-window"
        case lastPane = "last-pane"
        case nextWindow = "next-window"
        case previousWindow = "previous-window"
        case findWindow = "find-window"
        case clearHistory = "clear-history"
        case setHook = "set-hook"
        case popup
        case bindKey = "bind-key"
        case unbindKey = "unbind-key"
        case copyMode = "copy-mode"
        case setBuffer = "set-buffer"
        case pasteBuffer = "paste-buffer"
        case listBuffers = "list-buffers"
        case respawnPane = "respawn-pane"
        case displayMessage = "display-message"
    }

    enum TmuxShimCommandName: String, CLICommandName {
        case newSession = "new-session"
        case new
        case newWindow = "new-window"
        case neww
        case splitWindow = "split-window"
        case splitw
        case selectWindow = "select-window"
        case selectw
        case selectPane = "select-pane"
        case selectp
        case killWindow = "kill-window"
        case killw
        case killPane = "kill-pane"
        case killp
        case sendKeys = "send-keys"
        case send
        case capturePane = "capture-pane"
        case capturep
        case displayMessage = "display-message"
        case display
        case displayp
        case listWindows = "list-windows"
        case lsw
        case listPanes = "list-panes"
        case lsp
        case renameWindow = "rename-window"
        case renamew
        case resizePane = "resize-pane"
        case resizep
        case waitFor = "wait-for"
        case lastPane = "last-pane"
        case showBuffer = "show-buffer"
        case showb
        case saveBuffer = "save-buffer"
        case saveb
        case lastWindow = "last-window"
        case nextWindow = "next-window"
        case previousWindow = "previous-window"
        case setHook = "set-hook"
        case setBuffer = "set-buffer"
        case listBuffers = "list-buffers"
        case hasSession = "has-session"
        case has
        case selectLayout = "select-layout"
        case setOption = "set-option"
        case setCommand = "set"
        case setWindowOption = "set-window-option"
        case setw
        case sourceFile = "source-file"
        case refreshClient = "refresh-client"
        case attachSession = "attach-session"
        case detachClient = "detach-client"
        case versionLong = "-V"
        case versionShort = "-v"
    }

    enum ClaudeHookSubcommandName: String, CLICommandName {
        case sessionStart = "session-start"
        case active
        case stop
        case idle
        case promptSubmit = "prompt-submit"
        case notification
        case notify
        case sessionEnd = "session-end"
        case preToolUse = "pre-tool-use"
        case help
    }

    enum GenericAgentHookSubcommandName: String, CLICommandName {
        case sessionStart = "session-start"
        case promptSubmit = "prompt-submit"
        case stop
        case agentResponse = "agent-response"
        case shellExec = "shell-exec"
        case shellDone = "shell-done"
        case sessionEnd = "session-end"
    }

    static func parseCommandName<Command: CLICommandName>(_ type: Command.Type, raw: String) throws -> Command {
        do {
            let parseArgs = raw.hasPrefix("-") ? ["--", raw] : [raw]
            return try CommandNameArguments<Command>.parse(parseArgs).command
        } catch {
            throw CLIError(message: String(describing: error))
        }
    }

    func parseKnownCommandName<Command: CLICommandName>(_ type: Command.Type, raw: String) -> Command? {
        try? Self.parseCommandName(type, raw: raw)
    }

    static var argumentParserInventoryForms: [String] {
        var forms = Set(TopLevelCommandName.rawValues)

        forms.formUnion(prefixedForms("auth", AuthSubcommandName.rawValues))
        forms.formUnion(prefixedForms("feed", ["clear", "tui"]))
        forms.formUnion(prefixedForms("docs", DocsSubcommandName.rawValues))
        forms.formUnion(prefixedForms("settings", SettingsSubcommandName.rawValues))
        forms.formUnion(prefixedForms("hooks", HooksTargetName.rawValues))
        for agent in ["codex", "opencode", "cursor", "gemini", "copilot", "codebuddy", "factory", "qoder"] {
            forms.formUnion(prefixedForms("hooks \(agent)", HooksAgentActionName.rawValues))
            forms.formUnion(prefixedForms("hooks \(agent)", GenericAgentHookSubcommandName.rawValues))
        }
        forms.formUnion(prefixedForms("hooks claude", ClaudeHookSubcommandName.rawValues.filter { !$0.hasPrefix("-") && $0 != "help" }))
        forms.formUnion(prefixedForms("themes", ThemeSubcommandName.rawValues))
        forms.formUnion(["themes set --light", "themes set --dark"])
        forms.formUnion(prefixedForms("codex", AgentInstallerSubcommandName.rawValues))

        forms.formUnion(prefixedForms("vm", VMSubcommandName.rawValues))
        forms.formUnion(prefixedForms("cloud", VMSubcommandName.rawValues))
        forms.formUnion(TopLevelTmuxCommandName.rawValues)
        forms.formUnion(prefixedForms("__tmux-compat", TmuxShimCommandName.rawValues))
        forms.formUnion(prefixedForms("browser", BrowserSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser get", BrowserGetSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser is", BrowserIsSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser find", BrowserFindSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser frame", BrowserFrameSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser dialog", BrowserDialogSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser download", BrowserDownloadSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser cookies", BrowserCookiesSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser storage", BrowserStorageTypeName.rawValues))
        for storageType in BrowserStorageTypeName.rawValues {
            forms.formUnion(prefixedForms("browser storage \(storageType)", BrowserStorageOperationName.rawValues))
        }
        forms.formUnion(prefixedForms("browser tab", BrowserTabSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser console", BrowserLogSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser errors", BrowserLogSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser state", BrowserStateSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser trace", BrowserTraceSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser network", BrowserNetworkSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser screencast", BrowserScreencastSubcommandName.rawValues))
        forms.formUnion(prefixedForms("browser input", BrowserInputSubcommandName.rawValues))
        forms.formUnion(prefixedForms("markdown", MarkdownSubcommandName.rawValues))
        forms.formUnion(prefixedForms("claude-hook", ClaudeHookSubcommandName.rawValues.filter { !$0.hasPrefix("-") && $0 != "help" }))

        return forms.sorted()
    }

    static func prefixedForms(_ prefix: String, _ names: [String]) -> [String] {
        names.map { "\(prefix) \($0)" }
    }

    static func verifyArgumentParserInventory() throws {
        try verifyCommandNames(TopLevelCommandName.self)
        try verifyCommandNames(AgentInstallerSubcommandName.self)
        try verifyCommandNames(AuthSubcommandName.self)
        try verifyCommandNames(VMSubcommandName.self)
        try verifyCommandNames(FeedSubcommandName.self)
        try verifyCommandNames(DocsSubcommandName.self)
        try verifyCommandNames(SettingsSubcommandName.self)
        try verifyCommandNames(HooksTargetName.self)
        try verifyCommandNames(HooksAgentActionName.self)
        try verifyCommandNames(ThemeSubcommandName.self)
        try verifyCommandNames(BrowserSubcommandName.self)
        try verifyCommandNames(BrowserGetSubcommandName.self)
        try verifyCommandNames(BrowserIsSubcommandName.self)
        try verifyCommandNames(BrowserFindSubcommandName.self)
        try verifyCommandNames(BrowserFrameSubcommandName.self)
        try verifyCommandNames(BrowserDialogSubcommandName.self)
        try verifyCommandNames(BrowserDownloadSubcommandName.self)
        try verifyCommandNames(BrowserCookiesSubcommandName.self)
        try verifyCommandNames(BrowserStorageTypeName.self)
        try verifyCommandNames(BrowserStorageOperationName.self)
        try verifyCommandNames(BrowserTabSubcommandName.self)
        try verifyCommandNames(BrowserLogSubcommandName.self)
        try verifyCommandNames(BrowserStateSubcommandName.self)
        try verifyCommandNames(BrowserTraceSubcommandName.self)
        try verifyCommandNames(BrowserNetworkSubcommandName.self)
        try verifyCommandNames(BrowserScreencastSubcommandName.self)
        try verifyCommandNames(BrowserInputSubcommandName.self)
        try verifyCommandNames(MarkdownSubcommandName.self)
        try verifyCommandNames(TopLevelTmuxCommandName.self)
        try verifyCommandNames(TmuxShimCommandName.self)
        try verifyCommandNames(ClaudeHookSubcommandName.self)
        try verifyCommandNames(GenericAgentHookSubcommandName.self)

        for form in argumentParserInventoryForms {
            try verifyArgumentParserCommandForm(form)
        }
    }

    static func verifyCommandNames<Command: CLICommandName>(_ type: Command.Type) throws {
        for raw in Command.rawValues {
            _ = try parseCommandName(type, raw: raw)
        }
    }

    func runArgumentParserInventory(commandArgs: [String]) throws {
        let parsed: CommandInventoryArguments
        do {
            parsed = try CommandInventoryArguments.parse(commandArgs)
        } catch {
            throw CLIError(message: String(describing: error))
        }
        try Self.verifyArgumentParserInventory()
        let payload: [String: Any] = [
            "schema_version": 1,
            "verified": true,
            "forms": Self.argumentParserInventoryForms,
            "top_level": TopLevelCommandName.rawValues.sorted(),
        ]
        print(jsonString(payload))
        _ = parsed.json
        _ = parsed.verify
    }
}

extension CMUXCLI.CLICommandName {
    init?(argument: String) {
        self.init(rawValue: argument)
    }

    static var rawValues: [String] {
        allCases.map(\.rawValue)
    }
}
