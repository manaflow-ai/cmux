// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum AgentActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "agentPaneZoomIn",
                title: String(localized: "action.agentPaneZoomIn", defaultValue: "Agent Chat: Zoom In", bundle: .module),
                keywords: ["agent", "chat", "zoom", "bigger"], defaultShortcut: Shortcut("=", modifiers: [.command]),
                category: .agents, symbol: "plus.magnifyingglass", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                requires: [.agentPaneFocused], targets: [.pane], cliName: "agent zoom-in", mainMenu: .view
            ),
            ActionDescriptor(
                id: "agentPaneZoomOut",
                title: String(localized: "action.agentPaneZoomOut", defaultValue: "Agent Chat: Zoom Out", bundle: .module),
                keywords: ["agent", "chat", "zoom", "smaller"], defaultShortcut: Shortcut("-", modifiers: [.command]),
                category: .agents, symbol: "minus.magnifyingglass", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                requires: [.agentPaneFocused], targets: [.pane], cliName: "agent zoom-out", mainMenu: .view
            ),
            ActionDescriptor(
                id: "agentPaneZoomReset",
                title: String(localized: "action.agentPaneZoomReset", defaultValue: "Agent Chat: Actual Size", bundle: .module),
                keywords: ["agent", "chat", "zoom", "reset"], defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .agents, symbol: "1.magnifyingglass", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                requires: [.agentPaneFocused], targets: [.pane], cliName: "agent actual-size", mainMenu: .view
            ),
            ActionDescriptor(
                id: "agentChat.toggleNotificationMute",
                title: String(localized: "action.agentChat.toggleNotificationMute", defaultValue: "Mute/Unmute Chat Notifications", bundle: .module),
                keywords: ["mute", "silence", "quiet", "notifications", "agent", "chat"], category: .agents, symbol: "bell.slash",
                surfaces: [.palette, .contextMenu], targets: [.tab], cliName: "tab toggle-chat-notifications"
            ),
            // How many sub-sessions the chat runs at once (acpmux `_acpmux/subsession/limits`); a dialog,
            // so no CLI verb: `acpmux session limits` sets it from a shell.
            {
                var subagentLimit = ActionDescriptor(
                    id: "agentChat.subagentLimit",
                    title: String(localized: "action.agentChat.subagentLimit", defaultValue: "Chat Subagent Limit…", bundle: .module),
                    keywords: ["subagent", "sub-session", "limit", "parallel", "concurrency", "running", "agent", "chat"],
                    category: .agents, symbol: "slider.horizontal.3", surfaces: [.palette, .contextMenu], targets: [.tab],
                    // The chat's tab and its sidebar row (the chat's own menu is at its 12-row cap).
                    surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenus: [
                        ActionSurfaceCatalog.p(.tab, .identity, 206, folder: .options, label: ObjectMenuLabels.subagentLimit),
                    ])
                )
                // The dialog sends the change on a person connection (`_acpmux/subsession/limits` is
                // user-only): a socket caller must not open it and have it submitted for it.
                subagentLimit.isPersonOnly = true
                return subagentLimit
            }(),
            ActionDescriptor(
                id: "palette.newAgentChat",
                title: String(localized: "action.palette.newAgentChat", defaultValue: "New Agent Chat", bundle: .module),
                keywords: ["agent", "chat", "ai", "acpmux"], defaultShortcut: Shortcut("i", modifiers: [.command]),
                category: .agents, symbol: "bubble.left.and.bubble.right",
                surfaces: [.palette, .keyboard, .menu, .contextMenu],
                // These optional values are one schema for Cmd-I extensions, the palette chooser,
                // CLI and MCP. With none present the handler keeps Cmd-I's inherited seed.
                arguments: [
                    ActionArgument(name: "cwd", title: String(localized: "argument.agent.cwd", defaultValue: "Folder", bundle: .module), kind: .string, isRequired: false),
                    ActionArgument(name: "harness", title: String(localized: "argument.agent.harness", defaultValue: "Harness", bundle: .module), kind: .string, isRequired: false),
                    ActionArgument(name: "model", title: String(localized: "argument.agent.model", defaultValue: "Model", bundle: .module), kind: .string, isRequired: false),
                    CatalogArgument.agentHostMachine.optional,
                ],
                // A workspace target opens in its last focused pane; a pane or workspace that no
                // window shows gets the tab without being shown (AgentChatPlacement, #23016).
                targets: [.pane, .workspace], cliName: "agent new-chat", mainMenu: .file
            ),
            ActionDescriptor(
                id: "palette.newAgentChatOn",
                title: String(localized: "action.palette.newAgentChatOn", defaultValue: "New Agent Chat on…", bundle: .module),
                keywords: ["agent", "chat", "new", "host", "machine", "peer", "cloud", "remote"],
                category: .agents, symbol: "bubble.left.and.bubble.right", surfaces: [.palette],
                // Destination selection is the palette action's only step; it resolves the
                // destination's focused pane rather than capturing the local palette context.
                arguments: [CatalogArgument.agentHostMachine], targets: [],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.toggleSessionInfo",
                title: String(localized: "action.agentPane.toggleSessionInfo", defaultValue: "Toggle Session Info", bundle: .module),
                keywords: ["agent", "chat", "session", "session info", "context", "environment", "panel"],
                category: .agents, symbol: "sidebar.right", surfaces: [.palette, .keyboard],
                requires: [.agentPaneFocused], targets: [.pane], cliName: "agent toggle-session-info",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .guiOnly)
            ),
            // The chat header's toggles (AgentPageCommand): unavailable where the header has no button.
            ActionDescriptor(
                id: "agentPane.toggleFiles",
                title: String(localized: "action.agentPane.toggleFiles", defaultValue: "Toggle Files Beside Chat", bundle: .module),
                keywords: ["agent", "chat", "files", "file tree", "folder", "explorer", "beside", "split"],
                category: .agents, symbol: "folder", surfaces: [.palette],
                requires: [.agentPaneFocused], targets: [.pane], cliName: "agent toggle-files",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.togglePreview",
                title: String(localized: "action.agentPane.togglePreview", defaultValue: "Toggle Preview Beside Chat", bundle: .module),
                keywords: ["agent", "chat", "preview", "page", "web", "localhost", "beside", "split"],
                category: .agents, symbol: "play.rectangle", surfaces: [.palette],
                requires: [.agentPaneFocused], targets: [.pane], cliName: "agent toggle-preview",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.toggleSideTabs",
                title: String(localized: "action.agentPane.toggleSideTabs", defaultValue: "Toggle Tabs Beside Chat", bundle: .module),
                keywords: ["agent", "chat", "new tab", "hide tabs", "side tabs", "beside", "column"],
                category: .agents, symbol: "rectangle.split.2x1", surfaces: [.palette],
                requires: [.agentPaneFocused], targets: [.pane], cliName: "agent toggle-side-tabs",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .guiOnly)
            ),
            // The composer's and Session Info's controls (AgentPageCommand): unavailable where the chat has none.
            ActionDescriptor(
                id: "agentPane.runInBackground",
                title: String(localized: "action.agentPane.runInBackground", defaultValue: "Run in Background", bundle: .module),
                keywords: ["agent", "chat", "background", "ctrl-b", "detach", "command", "subagent", "move"],
                category: .agents, symbol: "arrow.down.to.line", surfaces: [.palette],
                requires: [.agentPaneFocused], targets: [.pane], cliName: "agent run-in-background",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.toggleQueueing",
                title: String(localized: "action.agentPane.toggleQueueing", defaultValue: "Toggle Prompt Queueing", bundle: .module),
                keywords: ["agent", "chat", "queue", "queueing", "steer", "send", "prompt", "turn"],
                category: .agents, symbol: "tray.full", surfaces: [.palette],
                requires: [.agentPaneFocused], targets: [.pane], cliName: "agent toggle-queueing",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.showSubagents",
                title: String(localized: "action.agentPane.showSubagents", defaultValue: "Show Subagents in Session Info", bundle: .module),
                keywords: ["agent", "chat", "subagents", "agents", "session info", "inspector", "children"],
                category: .agents, symbol: "person.2", surfaces: [.palette],
                requires: [.agentPaneFocused], targets: [.pane], cliName: "agent show-subagents",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.showBackgroundTasks",
                title: String(localized: "action.agentPane.showBackgroundTasks", defaultValue: "Show Background Tasks in Session Info", bundle: .module),
                keywords: ["agent", "chat", "background", "tasks", "commands", "servers", "session info", "inspector"],
                category: .agents, symbol: "gearshape", surfaces: [.palette],
                requires: [.agentPaneFocused], targets: [.pane], cliName: "agent show-background-tasks",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.toggleInspector",
                title: String(localized: "action.agentPane.toggleInspector", defaultValue: "Toggle Event Inspector", bundle: .module),
                keywords: ["agent", "chat", "event", "acp", "acpmux", "inspector", "log", "debug"], category: .agents, symbol: "list.bullet.rectangle",
                surfaces: [.palette, .contextMenu], targets: [.pane], cliName: "agent toggle-acp-inspector",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    ContextMenuPlacement(.agentChat, .inspect, 0, folder: .tools),
                ])
            ),
            ActionDescriptor(
                id: "agentPane.stopTurn",
                title: String(localized: "action.agentPane.stopTurn", defaultValue: "Stop Agent Turn", bundle: .module),
                keywords: ["agent", "chat", "stop", "cancel", "interrupt", "turn", "working", "generation"],
                category: .agents, symbol: "stop.circle", surfaces: [.palette, .keyboard],
                requires: [.agentPaneFocused], targets: [.pane], cliName: "agent stop-turn",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.togglePointerInspector",
                title: "Inspect UI Element",
                keywords: ["agent", "ui", "pointer", "inspect", "inspect element", "pick", "element", "debug"],
                category: .agents, symbol: "scope", surfaces: [.palette, .keyboard, .contextMenu],
                cliName: "agent toggle-ui-pointer",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    ContextMenuPlacement(.agentChat, .inspect, 1, folder: .tools, label: "Inspect Element"),
                    ContextMenuPlacement(.tab, .inspect, 510, label: "Inspect Element"),
                    ContextMenuPlacement(.pane, .inspect, 510, label: "Inspect Element"),
                    ContextMenuPlacement(.newTab, .inspect, 510, label: "Inspect Element"),
                    ContextMenuPlacement(.workspaceRow, .inspect, 510, label: "Inspect Element"),
                    ContextMenuPlacement(.sidebarItem, .inspect, 510, label: "Inspect Element"),
                    ContextMenuPlacement(.sidebarSection, .inspect, 510, folder: .options, label: "Inspect Element"),
                    ContextMenuPlacement(.windowBackground, .inspect, 510, label: "Inspect Element"),
                ])
            ),
            ActionDescriptor(
                id: "palette.quickAgentChat",
                title: String(localized: "action.palette.quickAgentChat", defaultValue: "Start Agent…", bundle: .module),
                keywords: ["agent", "start", "session", "launcher", "new", "chat", "ai", "acpmux", "quick", "composer", "summon"],
                // Ctrl-Cmd-Return (cx-hkat): Cmd-Shift-Return is Toggle Pane Zoom.
                defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: [.control, .command]),
                category: .agents, symbol: "bubble.left.and.text.bubble.right.fill",
                surfaces: [.palette, .keyboard, .menu], cliName: "agent quick", mainMenu: .file
            ),
            {
                // Start Agent's system-wide key, its own action so it has its own recorder and
                // stays off until `app.startAgentGlobalHotKey` (GlobalHotKeyService gates it).
                var anyApp = ActionDescriptor(
                    id: "palette.startAgentFromAnyApp",
                    title: String(localized: "action.palette.startAgentFromAnyApp", defaultValue: "Start Agent from Any App", bundle: .module),
                    keywords: ["agent", "start", "global", "hotkey", "hot key", "summon", "quick", "chat"],
                    // Ctrl-Opt-Cmd-Space: clear of ChatGPT's and Claude's quick-entry defaults.
                    defaultShortcut: Shortcut(Shortcut.spaceKey, modifiers: [.control, .option, .command]),
                    category: .agents, symbol: "bubble.left.and.text.bubble.right.fill", surfaces: [.keyboard],
                    // Start Agent offers the palette row, the menu item and the CLI verb.
                    surfacePlan: ActionSurfacePlan(palette: .exempt(.familyMember), cli: .exempt(.familyMember),
                                                   contextMenuExemption: .noObject)
                )
                anyApp.isGlobalHotKey = true
                return anyApp
            }(),
            ActionDescriptor(
                id: "palette.addHarness",
                title: String(localized: "action.palette.addHarness", defaultValue: "Integrate a Harness with an Agent…", bundle: .module),
                keywords: ["agent", "harness", "integrate", "acp", "acpmux", "custom", "bring your own"],
                category: .agents, symbol: "puzzlepiece.extension", surfaces: [.palette, .menu], mainMenu: .file,
                // Opens a chat that walks the user through `cmux harness guide`. Agents and
                // scripts run that guide (and `cmux harness add|doctor`) directly.
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            // Agent Stats (webviews/src/pages/stats, hq#1920): this computer's agent work from its
            // local session logs. A preview feature until styled (StatsHandlers), so it stays out of
            // the main menu, where an unavailable action shows greyed out to everyone.
            ActionDescriptor(
                id: "stats.show",
                title: String(localized: "action.stats.show", defaultValue: "Show Agent Stats", bundle: .module),
                keywords: ["stats", "statistics", "usage", "agent", "activity", "streak", "insights", "dashboard"],
                category: .agents, symbol: "chart.bar.xaxis", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "palette.toggleDictation",
                title: String(localized: "action.palette.toggleDictation", defaultValue: "Toggle Dictation", bundle: .module),
                keywords: ["dictation", "dictate", "voice", "speech", "microphone", "mic", "push to talk"],
                // Ctrl-Cmd-V: no terminal, shell or system meaning. Hold it to talk.
                defaultShortcut: Shortcut("v", modifiers: [.control, .command]),
                category: .agents, symbol: "mic", surfaces: [.palette, .keyboard, .menu],
                targets: [.pane], cliName: "agent toggle-dictation", mainMenu: .edit
            ),
            // Read aloud's Stop from anywhere (user, 2026-10-29: "I can't stop it"): the speaker under
            // a message reads through the app's one voice (CmuxNextAgentPane AgentPaneReadAloud).
            ActionDescriptor(
                id: "agentPane.stopReadingAloud",
                title: String(localized: "action.agentPane.stopReadingAloud", defaultValue: "Stop Reading Aloud", bundle: .module),
                keywords: ["read aloud", "speak", "speech", "voice", "stop", "silence", "mute", "speaker", "tts"],
                category: .agents, symbol: "speaker.slash", surfaces: [.palette],
                cliName: "agent stop-reading-aloud",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "agentPane.continueIn",
                title: String(localized: "action.agentPane.continueIn", defaultValue: "Continue In…", bundle: .module),
                keywords: ["agent", "chat", "continue", "handoff", "claude", "codex", "acpmux"],
                category: .agents, symbol: "arrow.turn.up.right", surfaces: [.palette],
                requires: [.agentPaneFocused], targets: [.pane],
                // The named CLI handoff is owned by acpmux. This action is the
                // user-facing chooser that invokes that same frontend flow.
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.switchModel",
                title: String(localized: "action.agentPane.switchModel", defaultValue: "Switch Model…", bundle: .module),
                keywords: ["agent", "chat", "model", "harness", "effort", "reasoning", "picker", "switch"],
                // Ctrl-Cmd-M (Lawrence 2026-10-09): an app chord, so it works wherever the agent
                // pane's keyboard is; the menu opens with the keyboard in its search field.
                defaultShortcut: Shortcut("m", modifiers: [.control, .command]),
                category: .agents, symbol: "cpu", surfaces: [.palette, .keyboard],
                requires: [.agentPaneFocused], targets: [.pane],
                // A chooser for a person. Scripts set the model with `cmux agent set-model --target
                // pane:|tab:|agent-chat:` (agentPane.setModel), so the CLI/MCP surface is exempt like Continue In….
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.createCheckpoint",
                title: String(localized: "action.agentPane.createCheckpoint", defaultValue: "Create Checkpoint", bundle: .module),
                keywords: ["agent", "git", "snapshot", "checkpoint", "handoff"],
                category: .agents, symbol: "camera", surfaces: [.palette],
                requires: [.agentPaneFocused, .checkpointCaptureAvailable], targets: [.pane],
                // CLI/MCP capture runs headlessly through git.checkpoint.create.
                // This action opens its GUI approval checklist, without writing.
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            // Search Files… (cx-ncc.69): the chat folder's files, and a pick mentions one in the
            // prompt. Only while an agent chat has the keyboard. It has no default key: Cmd-P is the
            // native Go to Workspace palette in every view, web views included (Lawrence 2026-10-19:
            // "All the web views should not have a built-in Cmd-P or Cmd-Shift-P"); the user can
            // still bind one. Scripts call `file.search` on the page's host instead.
            ActionDescriptor(
                id: "agentPane.searchFiles",
                title: String(localized: "action.agentPane.searchFiles", defaultValue: "Search Files…", bundle: .module),
                keywords: ["agent", "chat", "file", "files", "search", "find", "mention", "open", "quick"],
                category: .agents, symbol: "doc.text.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.agentPaneFocused], targets: [.pane],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            // Copy Last Code Block (Opt-Cmd-;) and Archive Chat (Ctrl-Cmd-A), as in the Codex app
            // (cx-ncc.72). Only while an agent chat has the keyboard. Archive runs the chat menu's
            // Archive, or on a Priority row (an `agent-chat:` target) archives that row's chat;
            // scripts use `cmux acp` and the chat's own transcript instead.
            ActionDescriptor(
                id: "agentPane.copyLastCodeBlock",
                title: String(localized: "action.agentPane.copyLastCodeBlock", defaultValue: "Copy Last Code Block", bundle: .module),
                keywords: ["agent", "chat", "code", "block", "copy", "snippet", "answer", "reply"],
                defaultShortcut: Shortcut(";", modifiers: [.command, .option]),
                category: .agents, symbol: "doc.on.clipboard", surfaces: [.palette, .keyboard],
                requires: [.agentPaneFocused], targets: [.pane],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.archiveChat",
                title: String(localized: "action.agentPane.archiveChat", defaultValue: "Archive Chat", bundle: .module),
                keywords: ["agent", "chat", "archive", "hide", "close", "done"],
                defaultShortcut: Shortcut("a", modifiers: [.command, .control]),
                category: .agents, symbol: "archivebox", surfaces: [.palette, .keyboard, .contextMenu],
                // A script names the chat's pane (`--target pane:…`); the target brings its own
                // agentPaneFocused fact (`ActionRegistry.targetContext`), as a Priority row's
                // `agent-chat:` target does (`ActionContext.implied(byTargetKind:)`).
                requires: [.agentPaneFocused], targets: [.pane, .agentChat], cliName: "agent archive-chat",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ContextMenuPlacement(.priorityRow, .close, 0)])
            ),
            ActionDescriptor(
                id: "agentPane.git.commit",
                title: String(localized: "action.agentPane.git.commit", defaultValue: "Commit Changes…", bundle: .module),
                keywords: ["agent", "git", "commit", "changes", "stage", "message"],
                category: .agents, symbol: "checkmark.circle", surfaces: [.palette],
                requires: [.agentPaneFocused], targets: [.pane],
                // The session host owns `cmux git commit` (git.commit); this
                // action opens the changes view's commit form for that op.
                // Palette only, as the other agentPane actions: no default
                // shortcut (no free chord that means commit in a terminal-
                // first app), and no menu-bar or right-click item, because
                // it acts on the focused chat's changes view, which has no
                // menu of its own. The toolbar button is its other entrypoint.
                surfacePlan: ActionSurfacePlan(cli: .exempt(.ownerVerb), contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "agentPane.git.push",
                title: String(localized: "action.agentPane.git.push", defaultValue: "Push Branch", bundle: .module),
                keywords: ["agent", "git", "push", "upload", "remote", "branch", "upstream"],
                category: .agents, symbol: "arrow.up.circle", surfaces: [.palette],
                requires: [.agentPaneFocused], targets: [.pane],
                // The session host owns `cmux git push` (git.push); this runs
                // the changes view's Push button, which never forces. Palette
                // only, for the reasons given for agentPane.git.commit.
                surfacePlan: ActionSurfacePlan(cli: .exempt(.ownerVerb), contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "agentPane.searchChats",
                title: String(localized: "action.agentPane.searchChats", defaultValue: "Search Agent Chats", bundle: .module),
                keywords: ["agent", "chat", "search", "find", "sessions", "acpmux"],
                // Cmd-K outside a terminal (KeyBindingDefaults.scopedEntries; Leo 2026-10-12):
                // decision K1 keeps Cmd-K as Clear in a terminal, so the catalog key stays
                // unset. The command palette's chats page lists every chat.
                category: .agents, symbol: "magnifyingglass", surfaces: [.palette, .keyboard]
            ),
            permissionAction("allowOnce", title: String(localized: "action.agentPane.permission.allowOnce", defaultValue: "Allow Once", bundle: .module), symbol: "checkmark", shortcut: Shortcut("1", modifiers: [.command, .option])),
            permissionAction("allowChat", title: String(localized: "action.agentPane.permission.allowChat", defaultValue: "Allow for This Chat", bundle: .module), symbol: "checkmark.circle", shortcut: Shortcut("2", modifiers: [.command, .option])),
            permissionAction("deny", title: String(localized: "action.agentPane.permission.deny", defaultValue: "Deny", bundle: .module), symbol: "xmark", shortcut: Shortcut("3", modifiers: [.command, .option])),
            permissionAction("expand", title: String(localized: "action.agentPane.permission.expand", defaultValue: "Expand Permission Details", bundle: .module), symbol: "arrow.down.right.and.arrow.up.left", shortcut: Shortcut("4", modifiers: [.command, .option])),
            permissionAction("retry", title: String(localized: "action.agentPane.permission.retry", defaultValue: "Check and Retry Permission", bundle: .module), symbol: "arrow.clockwise"),
            permissionAction("revoke", title: String(localized: "action.agentPane.permission.revoke", defaultValue: "Revoke Chat Permission", bundle: .module), symbol: "hand.raised"),
            permissionAction("refresh", title: String(localized: "action.agentPane.permission.refresh", defaultValue: "Refresh Permissions", bundle: .module), symbol: "arrow.clockwise.circle"),
            ActionDescriptor(
                id: "palette.openTerminalChatView",
                title: String(localized: "action.palette.openTerminalChatView", defaultValue: "Open Terminal as Chat", bundle: .module),
                keywords: ["agent", "chat"], category: .agents, symbol: "text.bubble", surfaces: [.palette],
                requires: [.terminalFocused], cliName: "agent open-terminal-as-chat"
            ),
            ActionDescriptor(
                id: "palette.launchClaudeTeams",
                title: String(localized: "action.palette.launchClaudeTeams", defaultValue: "Launch Claude Teams", bundle: .module),
                keywords: ["agent", "claude", "team"], category: .agents, symbol: "person.3", surfaces: [.palette],
                cliName: "agent launch-claude-teams"
            ),
            ActionDescriptor(
                id: "palette.launchCodexTeams",
                title: String(localized: "action.palette.launchCodexTeams", defaultValue: "Launch Codex Teams", bundle: .module),
                keywords: ["agent", "codex", "team"], category: .agents, symbol: "person.3.fill", surfaces: [.palette],
                cliName: "agent launch-codex-teams"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversation",
                title: String(localized: "action.palette.forkAgentConversation", defaultValue: "Fork Conversation", bundle: .module),
                keywords: ["agent", "fork", "branch"], defaultShortcut: Shortcut("y", modifiers: [.option, .command]),
                category: .agents, symbol: "arrow.triangle.branch", surfaces: [.palette, .contextMenu],
                cliName: "agent fork-conversation"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationTo",
                title: String(localized: "action.palette.forkAgentConversationTo", defaultValue: "Fork To…", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "arrow.turn.up.right",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationRight",
                title: String(localized: "action.palette.forkAgentConversationRight", defaultValue: "Fork Conversation to the Right", bundle: .module),
                keywords: ["agent", "fork", "branch", "split"],
                category: .agents, symbol: "rectangle.righthalf.inset.filled",
                surfaces: [.palette, .contextMenu],
                cliName: "agent fork-conversation-to-right"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationLeft",
                title: String(localized: "action.palette.forkAgentConversationLeft", defaultValue: "Fork Conversation to the Left", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "rectangle.lefthalf.inset.filled",
                surfaces: [.palette, .contextMenu],
                cliName: "agent fork-conversation-to-left"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationTop",
                title: String(localized: "action.palette.forkAgentConversationTop", defaultValue: "Fork Conversation Above", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "rectangle.tophalf.inset.filled",
                surfaces: [.palette, .contextMenu],
                cliName: "agent fork-conversation-above"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationBottom",
                title: String(localized: "action.palette.forkAgentConversationBottom", defaultValue: "Fork Conversation Below", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "rectangle.bottomhalf.inset.filled",
                surfaces: [.palette, .contextMenu],
                cliName: "agent fork-conversation-below"
            ),
            // u18673: a fork in a new strip column on either side of the chat's column, or a new row
            // below it, as New Column Right / New Column Left / New Row open a terminal.
            ActionDescriptor(
                id: "palette.forkAgentConversationNewColumnRight",
                title: String(localized: "action.palette.forkAgentConversationNewColumnRight", defaultValue: "Fork Conversation to New Column Right", bundle: .module),
                keywords: ["agent", "fork", "column", "right"], category: .agents, symbol: "rectangle.split.3x1",
                surfaces: [.palette, .contextMenu],
                cliName: "agent fork-conversation-to-new-column-right"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationNewColumnLeft",
                title: String(localized: "action.palette.forkAgentConversationNewColumnLeft", defaultValue: "Fork Conversation to New Column Left", bundle: .module),
                keywords: ["agent", "fork", "column", "left"], category: .agents, symbol: "rectangle.leftthird.inset.filled",
                surfaces: [.palette, .contextMenu],
                cliName: "agent fork-conversation-to-new-column-left"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationNewRow",
                title: String(localized: "action.palette.forkAgentConversationNewRow", defaultValue: "Fork Conversation to New Row", bundle: .module),
                keywords: ["agent", "fork", "row", "below"], category: .agents, symbol: "rectangle.grid.1x2",
                surfaces: [.palette, .contextMenu],
                cliName: "agent fork-conversation-to-new-row"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationNewTab",
                title: String(localized: "action.palette.forkAgentConversationNewTab", defaultValue: "Fork Conversation to New Tab", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "plus.square",
                surfaces: [.palette, .contextMenu],
                cliName: "agent fork-conversation-to-new-tab"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationNewWorkspace",
                title: String(localized: "action.palette.forkAgentConversationNewWorkspace", defaultValue: "Fork Conversation to New Workspace", bundle: .module),
                keywords: ["agent", "fork"], category: .agents, symbol: "rectangle.stack.badge.plus",
                surfaces: [.palette, .contextMenu],
                cliName: "agent fork-conversation-to-new-workspace"
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationNewWindow",
                title: String(localized: "action.palette.forkAgentConversationNewWindow", defaultValue: "Fork Conversation to New Window", bundle: .module),
                keywords: ["agent", "fork", "window"], category: .agents, symbol: "macwindow.badge.plus",
                surfaces: [.palette, .contextMenu],
                cliName: "agent fork-conversation-to-new-window"
            ),
            ActionDescriptor(
                id: "palette.computerUse.setup",
                title: String(localized: "action.palette.computerUse.setup", defaultValue: "Computer Use Setup", bundle: .module),
                keywords: ["agent", "automation"], category: .agents, symbol: "cursorarrow.click.2",
                surfaces: [.palette], cliName: "agent computer-use-setup"
            ),
            ActionDescriptor(
                id: "palette.computerUse.restart",
                title: String(localized: "action.palette.computerUse.restart", defaultValue: "Restart Computer Use Helper", bundle: .module),
                keywords: ["agent", "automation", "restart"], category: .agents, symbol: "arrow.clockwise",
                surfaces: [.palette], cliName: "agent restart-computer-use-helper"
            ),
            ActionDescriptor(
                id: "palette.computerUse.accessibility",
                title: String(localized: "action.palette.computerUse.accessibility", defaultValue: "Grant Accessibility Access", bundle: .module),
                keywords: ["agent", "permissions", "tcc"], category: .agents, symbol: "accessibility",
                surfaces: [.palette], cliName: "agent grant-accessibility-access"
            ),
            ActionDescriptor(
                id: "palette.computerUse.screenRecording",
                title: String(localized: "action.palette.computerUse.screenRecording", defaultValue: "Grant Screen Recording Access", bundle: .module),
                keywords: ["agent", "permissions", "tcc"], category: .agents, symbol: "record.circle",
                surfaces: [.palette], cliName: "agent grant-screen-recording-access"
            ),
            // The Home Chief's subagents (optchat-chief spawn) and scripts
            // (`cmux agent open SESSION`): a workspace whose tab is an existing
            // acpmux session's chat.
            ActionDescriptor(
                id: "agent.openSessionWorkspace",
                title: String(localized: "action.agent.openSessionWorkspace", defaultValue: "Open Agent Session in New Workspace", bundle: .module),
                keywords: ["agent", "session", "acpmux", "subagent", "workspace"], category: .agents,
                symbol: "bubble.left.and.text.bubble.right", surfaces: [.keyboard],
                arguments: [
                    ActionArgument(name: "session", title: String(localized: "argument.agent.session", defaultValue: "Session", bundle: .module),
                                   kind: .string),
                    ActionArgument(name: "name", title: String(localized: "argument.agent.workspaceName", defaultValue: "Workspace Name", bundle: .module),
                                   kind: .string, isRequired: false),
                    ActionArgument(name: "key", title: String(localized: "argument.agent.workspaceKey", defaultValue: "Workspace Key", bundle: .module),
                                   kind: .string, isRequired: false),
                    ActionArgument(name: "cwd", title: String(localized: "argument.agent.cwd", defaultValue: "Folder", bundle: .module),
                                   kind: .string, isRequired: false),
                    ActionArgument(name: "host", title: String(localized: "argument.agent.host", defaultValue: "Session Host", bundle: .module),
                                   kind: .string, isRequired: false),
                    // A group's name (made when missing), not a target: a launcher names it.
                    ActionArgument(name: "group", title: String(localized: "argument.group", defaultValue: "Group", bundle: .module),
                                   kind: .string, isRequired: false),
                    // `top`: first in the sidebar (below Home), over workspaces.newPlacement (#29875).
                    ActionArgument(name: "placement", title: String(localized: "argument.agent.placement", defaultValue: "Placement", bundle: .module),
                                   kind: .string, isRequired: false),
                ],
                cliName: "agent open",
                // It makes a workspace and its chat tab (no terminal): action.run
                // waits the terminal start deadline, not 2 s, so the caller's run
                // ends once the workspace exists (it renames it later by key).
                startsTerminal: true,
                surfacePlan: ActionSurfacePlan(palette: .exempt(.noObject), cli: .offered, contextMenuExemption: .noObject)
            ),
            // Agents and scripts (`cmux agent open-tab SESSION`): an existing acpmux session's chat as a tab of a pane.
            ActionDescriptor(
                id: "agent.openSessionTab",
                title: String(localized: "action.agent.openSessionTab", defaultValue: "Open Agent Session in Tab", bundle: .module),
                keywords: ["agent", "session", "acpmux", "subagent", "tab", "chat"], category: .agents,
                symbol: "bubble.left.and.text.bubble.right", surfaces: [.keyboard],
                arguments: [
                    ActionArgument(name: "session", title: String(localized: "argument.agent.session", defaultValue: "Session", bundle: .module),
                                   kind: .string),
                    ActionArgument(name: "host", title: String(localized: "argument.agent.host", defaultValue: "Session Host", bundle: .module),
                                   kind: .string, isRequired: false),
                ],
                targets: [.pane, .tab], cliName: "agent open-tab",
                surfacePlan: ActionSurfacePlan(palette: .exempt(.noObject), cli: .offered, contextMenuExemption: .noObject)
            ),
            // The Home Chief's settings sidebar (the header's name pill does the same).
            ActionDescriptor(
                id: "home.toggleChiefSettings",
                title: String(localized: "action.home.toggleChiefSettings", defaultValue: "Toggle Chief Settings", bundle: .module),
                keywords: ["chief", "home", "engine", "model", "harness", "settings"], category: .agents,
                symbol: "sidebar.right", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            // Stops the Home Chief's running turn (chief.stop); the compose bar's
            // stop button, Esc and Cmd-. in its field run this one action.
            ActionDescriptor(
                id: "home.stopChief",
                title: String(localized: "action.home.stopChief", defaultValue: "Stop the Chief", bundle: .module),
                keywords: ["chief", "home", "stop", "cancel", "interrupt", "turn"], category: .agents,
                symbol: "stop.circle", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            // The built-in Memory Inspector (memory-inspector-native-DESIGN.md): a
            // Chief's memory tree, search, and the owner's edits, deletes and undo,
            // in a native pane tab in the Home right column. Every build.
            ActionDescriptor(
                id: "chief.openMemoryInspector",
                title: String(localized: "action.chief.openMemoryInspector", defaultValue: "Chief: Open Memory Inspector", bundle: .module),
                keywords: ["chief", "memory", "optchat", "view", "zoom", "tree", "edit", "delete", "forget", "inspector"],
                category: .agents, symbol: "brain", surfaces: [.palette], cliName: "chief memory",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // The Home header's Memory toggle (top right, like Claude desktop's panel buttons): closes
            // the window's Memory Inspector tabs when one shows, else opens one as the action above
            // (the same `chief` and `server` arguments).
            ActionDescriptor(
                id: "chief.toggleMemoryInspector",
                title: String(localized: "action.chief.toggleMemoryInspector", defaultValue: "Chief: Toggle Memory Inspector", bundle: .module),
                keywords: ["chief", "memory", "inspector", "panel", "show", "hide", "close"],
                category: .agents, symbol: "brain", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            // Chief Usage (chief-usage-analytics-DESIGN.md): tokens, cost, cache hit and turn
            // time of this Mac's Chiefs, as a page tab (Home's right column in Home). The
            // Chief's row menu in Home runs it too. `cmux chief usage` prints the same summary.
            // Move Chief To… (remote-groups-DESIGN.md slice 6, chief-migration-DESIGN.md 8a): This Mac, a
            // remote group or cmux Cloud; a dry run's report first, then the move and `move reach`.
            // `cmux action run chief.moveTo --arg target=…` reaches it by id.
            ActionDescriptor(
                id: "chief.moveTo",
                title: String(localized: "action.chief.moveTo", defaultValue: "Move Chief To…", bundle: .module),
                keywords: ["chief", "move", "migrate", "host", "remote", "mac mini", "linux", "vm", "cloud"],
                category: .agents, symbol: "arrow.right.circle", surfaces: [.palette],
                arguments: [ActionArgument(name: "target", title: String(localized: "argument.chiefMoveTarget", defaultValue: "Target", table: "RemoteActions", bundle: .module),
                                           kind: .string, isRequired: false,
                                           suggestions: ActionSuggestions(source: ActionSuggestions.chiefMoveTargets, pinned: []))],
                destructive: true,
                // `cmux chief move --to` and the Chief's MCP `move` tool run the same move (one implementation).
                surfacePlan: ActionSurfacePlan(cli: .exempt(.familyMember), contextMenuExemption: .noObject)
            ),
            // Import Memories… (chief-memory-import-DESIGN.md): finds what Claude Code, Codex, ChatGPT and claude.ai
            // exports left on this Mac and brings it into a Chief in the background (`optchat-chief memory
            // import-from` is the CLI). `chief` names a Cloud Chief to import into; `source` skips the question.
            ActionDescriptor(
                id: "chief.importMemories",
                title: String(localized: "action.chief.importMemories", defaultValue: "Import Memories…", bundle: .module),
                keywords: ["chief", "memory", "memories", "import", "claude", "claude code", "codex", "chatgpt", "openai", "bring", "migrate", "onboard"],
                category: .agents, symbol: "square.and.arrow.down", surfaces: [.palette],
                arguments: [
                    ActionArgument(name: "chief", title: String(localized: "argument.chiefImportChief", defaultValue: "Cloud Chief", bundle: .module),
                                   kind: .string, isRequired: false),
                    ActionArgument(name: "source", title: String(localized: "argument.chiefImportSource", defaultValue: "Source", bundle: .module),
                                   kind: .string, isRequired: false),
                ],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "chief.importMemories.undo",
                title: String(localized: "action.chief.importMemories.undo", defaultValue: "Undo Last Memory Import", bundle: .module),
                keywords: ["chief", "memory", "memories", "import", "undo", "take back", "restore"],
                category: .agents, symbol: "arrow.uturn.backward", surfaces: [.palette],
                arguments: [ActionArgument(name: "chief", title: String(localized: "argument.chiefImportChief", defaultValue: "Cloud Chief", bundle: .module),
                                           kind: .string, isRequired: false)],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "chief.openUsage",
                title: String(localized: "action.chief.openUsage", defaultValue: "Chief Usage", bundle: .module),
                keywords: ["chief", "usage", "cost", "tokens", "cache", "spend", "stats", "analytics"],
                category: .agents, symbol: "dollarsign.circle", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            // The Chief view gallery: experimental views beside the Chief (where every agent is,
            // an agent board, the CI fleet, landing PRs, today's timeline), as a page tab in Home's
            // right column. Debug Settings > Home > "Chief view gallery"; DEV and NIGHTLY only.
            ActionDescriptor(
                id: "chief.openViews",
                title: String(localized: "action.chief.openViews", defaultValue: "Chief View Gallery", bundle: .module),
                keywords: ["chief", "views", "gallery", "agents", "where", "everybody", "board", "fleet", "landing", "timeline"],
                category: .agents, symbol: "square.grid.2x2", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "agentActivity.open",
                title: String(localized: "action.agentActivity.open", defaultValue: "Agent Activity", bundle: .module),
                keywords: ["agent", "computer use", "cua", "timeline", "screenshots", "automation"], category: .agents,
                symbol: "cursorarrow.click.2", surfaces: [.palette, .menu], cliName: "agent activity", mainMenu: .window
            ),
            ActionDescriptor(
                id: "computerUseFocus",
                title: String(localized: "action.computerUseFocus", defaultValue: "Focus Computer Use", bundle: .module),
                keywords: ["agent", "automation"], category: .agents, symbol: "cursorarrow.rays", surfaces: [.menu],
                cliName: "agent focus-computer-use", mainMenu: .file
            ),
            ActionDescriptor(
                id: "computerUseFocusCallingTerminal",
                title: String(localized: "action.computerUseFocusCallingTerminal", defaultValue: "Focus Calling Terminal", bundle: .module),
                keywords: ["agent", "automation"], category: .agents, symbol: "terminal", surfaces: [.menu],
                cliName: "agent focus-calling-terminal", mainMenu: .file
            ),
            ActionDescriptor(
                id: "computerUseStop",
                title: String(localized: "action.computerUseStop", defaultValue: "Stop Computer Use", bundle: .module),
                keywords: ["agent", "automation"], category: .agents, symbol: "stop.circle", surfaces: [.menu],
                cliName: "agent stop-computer-use", mainMenu: .file
            ),
        ]
    }

    private static func permissionAction(_ name: String, title: String, symbol: String,
                                         shortcut: Shortcut? = nil) -> ActionDescriptor {
        var action = ActionDescriptor(
            id: ActionID(rawValue: "agentPane.permission.\(name)"),
            title: title,
            keywords: ["agent", "permission", "tool", name], defaultShortcut: shortcut,
            category: .agents, symbol: symbol, surfaces: [.keyboard],
            requires: [.agentPaneFocused], targets: [.pane],
            surfacePlan: ActionSurfacePlan(
                cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly
            )
        )
        // GUI-only permission controls must not let a socket caller approve
        // its own request, including one claiming a user origin.
        action.isPersonOnly = true
        return action
    }
}
