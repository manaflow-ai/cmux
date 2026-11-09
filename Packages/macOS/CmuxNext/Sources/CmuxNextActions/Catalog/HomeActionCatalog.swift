// Home (plans/cmux-next/home.md): the pinned sidebar row that shows the native
// conversations screen. Cmd+1 reaches it through `selectWorkspaceByNumber`
// (digit 1); this action is the palette, menu and CLI path.
// `home.attachFiles` is the one action behind the composer's attach button:
// the palette opens the file picker; `cmux home attach <path>` hands a file to
// the shown Home composer through the same intake as a drop.

nonisolated enum HomeActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        // Owner round trips a caller that waits (`action.run` with `wait`) gets the
        // 40 s result deadline for: a group with invites takes several requests.
        let waits: Set<ActionID> = ["home.newMessage", "home.invite", "home.inviteToTeam", "home.newChief", "home.archiveChief", "home.deleteChief", "home.setPrimaryChief",
                                    "home.renameConversation", "home.addMembers", "home.removeMember", "home.leaveConversation",
                                    "home.muteConversation", "home.unmuteConversation", "home.sendMessage",
                                    "home.createGroup", "home.setChiefReplies", "home.createChannel"]
        return (all + debugOnly).map { descriptor in
            var descriptor = descriptor
            descriptor.waitsForResult = waits.contains(descriptor.id)
            // Invite to Team sends only from its dialog, where the person sees the seat cost and
            // presses Send: a CLI or agent run waits for that answer.
            descriptor.waitsForPerson = descriptor.id == "home.inviteToTeam"
            // `home.chiefPetEnabled` is a user-only setting: only a person turns the pet on. Only the
            // person adopts a Chief or sets its engine (the owner refuses an agent's `cmux chief
            // adopt|engine`), so no script reaches the owner through these as the app.
            descriptor.isPersonOnly = ["home.toggleChiefPet", "home.messageChiefPet", "home.messageChiefFromAnyApp",
                                       "home.adoptChief", "home.setChiefModel", "home.setChiefEffort"].contains(descriptor.id)
            return descriptor
        }
    }

    /// Which Chief an Archive, Make Primary or Delete acts on: its id from the CLI, a pick of the
    /// user's Chiefs in the palette.
    private static var chiefArgument: ActionArgument {
        ActionArgument(name: "chief", title: t("argument.home.chief.id", "Chief"), kind: .string,
                       suggestions: ActionSuggestions(source: ActionSuggestions.homeChiefs, pinned: []))
    }

    /// Which of this Mac's Chiefs an Edit or engine change acts on: a pick of its registry's Chiefs.
    private static var localChief: ActionArgument {
        ActionArgument(name: "chief", title: t("argument.home.chief.id", "Chief"), kind: .string,
                       suggestions: ActionSuggestions(source: ActionSuggestions.localChiefs, pinned: []))
    }

    private static var all: [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "home.show",
                title: String(localized: "action.home.show", defaultValue: "Go to Home", bundle: .module),
                keywords: ["home", "mux", "messages", "conversations", "orchestrator"], category: .window, symbol: "house",
                surfaces: [.palette, .keyboard, .menu], cliName: "home show",
                mainMenu: .file
            ),
            // The Chief's conversation in the Home workspace's chat pane: the sidebar's Chief item
            // (`ChiefSidebar`, off by default) runs it, and so can the palette and `cmux home open-chief`.
            ActionDescriptor(
                id: "home.openChief", title: t("action.home.openChief", "Open Chief"),
                keywords: ["chief", "home", "chat", "conversation", "talk", "mux", "orchestrator", "subagents"],
                category: .window, symbol: "sparkles", surfaces: [.palette, .keyboard], cliName: "home open-chief",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // The native Home as a pane tab (HomePageTab): it splits next to any other tab
            // (the channels Home among them) over the same Home data. Each run opens one more.
            ActionDescriptor(
                id: "home.tab", title: t("action.home.tab", "Open Home in Tab"),
                keywords: ["home", "tab", "split", "pane", "messages", "conversations", "side by side"],
                category: .window, symbol: "house", surfaces: [.palette, .menu], cliName: "home tab",
                mainMenu: .file,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // The channels Home (webviews/src/pages/home-channels) as a tab next to the native
            // Home, over the same Home data, so both can be open at once. Only while Channels is
            // enabled (hq-6d 2026-10-15): hidden from the palette and menus and refused otherwise.
            ActionDescriptor(
                id: "home.channels", title: t("action.home.channels", "Open Channels"),
                keywords: ["home", "channels", "threads", "direct messages", "conversations", "messages"],
                category: .window, symbol: "number", surfaces: [.palette, .menu], requires: [.homeChannelsEnabled], cliName: "home channels",
                mainMenu: .file,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // The docked Home's two views of the same data, the sidebar's Home and Channels entries
            // (Lawrence 2026-10-15: "2 diff things in section like Home and Channels"): `messages` is
            // Home (native, the default), `channels` the React page while Channels is enabled. The
            // Channels entry's click and the page's cmux.host.home.switchView run it. No `view`: the
            // other one. No default shortcut (Ctrl-Option-Cmd-H is gone with the header switch).
            ActionDescriptor(
                id: "home.switchView", title: t("action.home.switchView", "Switch Home View"),
                keywords: ["home", "messages", "channels", "slack", "imessage", "view", "toggle", "switch", "layout"],
                category: .window, symbol: "arrow.left.arrow.right", surfaces: [.palette, .keyboard, .menu],
                arguments: [ActionArgument(name: "view", title: t("argument.home.view", "View"),
                                           kind: .enumeration([ActionEnumCase(value: "messages", title: t("argument.home.view.messages", "Home")),
                                                               ActionEnumCase(value: "channels", title: t("argument.home.view.channels", "Channels"))]),
                                           isRequired: false)],
                cliName: "home switch-view",
                mainMenu: .view,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // The Channels entry after Home is off by default; the palette turns it on and off
            // (`home.channelsEnabled`; Lawrence 2026-10-15: "u have to cmd shift p to enable channels
            // in the first place"). The palette lists the one that changes something.
            ActionDescriptor(
                id: "home.enableChannels", title: t("action.home.enableChannels", "Enable Channels"),
                keywords: ["home", "channels", "slack", "threads", "enable", "show", "sidebar"],
                category: .window, symbol: "number", surfaces: [.palette], cliName: "home enable-channels",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "home.disableChannels", title: t("action.home.disableChannels", "Disable Channels"),
                keywords: ["home", "channels", "slack", "threads", "disable", "hide", "sidebar"],
                category: .window, symbol: "number", surfaces: [.palette], cliName: "home disable-channels",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // The Chief pet (`home.chiefPetEnabled`, off by default): Leo 2026-10-19, the toggle "ought to be a
            // hell of a lot more obvious" than Settings > Home. View > Show Chief Pet and the palette row read as
            // the change they make (Hide Chief Pet while it shows); the empty Chief conversation offers it too.
            ActionDescriptor(
                id: "home.toggleChiefPet", title: t("action.home.toggleChiefPet", "Show Chief Pet"),
                keywords: ["chief", "pet", "mascot", "floating", "companion", "show", "hide", "toggle", "buddy", "notifications"],
                category: .window, symbol: "pawprint", surfaces: [.palette, .menu],
                mainMenu: .view,
                // No CLI verb: the setting is user-only, so a script or agent run would be refused.
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            // The pet with its reply box open, turning the pet on first if it is off (Leo 2026-10-20: grow the
            // pet toward Codex's mini chat). Bindable in Settings > Keyboard Shortcuts, unbound by default.
            ActionDescriptor(
                id: "home.messageChiefPet", title: t("action.home.messageChiefPet", "Message the Chief"),
                keywords: ["chief", "pet", "message", "reply", "ask", "chat", "mini", "floating", "summon", "quick"],
                category: .window, symbol: "bubble.left", surfaces: [.palette, .keyboard],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            {
                // Message the Chief's system-wide key, its own action so it has its own recorder (like Start Agent
                // from Any App). GlobalHotKeyService registers it only while the pet is on: the person already chose
                // to have the Chief over every app, and with the pet off the key stays with other apps.
                var anyApp = ActionDescriptor(
                    id: "home.messageChiefFromAnyApp",
                    title: t("action.home.messageChiefFromAnyApp", "Message the Chief from Any App"),
                    keywords: ["chief", "pet", "message", "reply", "ask", "chat", "global", "hotkey", "hot key", "summon"],
                    // Ctrl-Opt-Cmd-C: free in cmux's defaults, Ghostty's reserved keys and macOS's; C for Chief.
                    defaultShortcut: Shortcut("c", modifiers: [.control, .option, .command]),
                    category: .window, symbol: "bubble.left", surfaces: [.keyboard],
                    // Message the Chief is the palette row.
                    surfacePlan: ActionSurfacePlan(palette: .exempt(.familyMember), cli: .exempt(.familyMember),
                                                   contextMenuExemption: .noObject)
                )
                anyApp.isGlobalHotKey = true
                return anyApp
            }(),
            ActionDescriptor(
                id: "home.attachFiles", title: t("action.home.attachFiles", "Attach Files…"),
                keywords: ["home", "attach", "file", "photo", "video", "image", "upload", "message", "conversation"],
                category: .window, symbol: "paperclip", surfaces: [.palette, .keyboard],
                arguments: [ActionArgument(name: "path", title: t("argument.home.attach.path", "File Path"), kind: .string,
                                           isRequired: false)],
                cliName: "home attach",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // Reply to Selection (plans/cmux-next/reply-to-selection-DESIGN.md): the text selected in one
            // message of the shown Home conversation is the reply's quote. Cmd-Shift-R on Home (KeyBindingDefaults).
            ActionDescriptor(
                id: "home.replyToSelection", title: t("action.home.replyToSelection", "Reply to Selection"),
                keywords: ["home", "reply", "quote", "selection", "selected", "highlight", "message", "thread"],
                category: .window, symbol: "text.quote", surfaces: [.palette, .keyboard],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.liveInput), contextMenuExemption: .liveInput)
            ),
            // Chief zoom: Cmd-= (and Cmd-+), Cmd-- and Cmd-0 on Home (KeyBindingDefaults.scopedDefaults) step
            // the Agent Chat Zoom setting (`agentPane.zoom`), which the Chief transcript follows like an agent chat.
            ActionDescriptor(
                id: "home.zoomIn", title: t("action.home.zoomIn", "Chief: Zoom In"),
                keywords: ["home", "chief", "chat", "zoom", "bigger", "text size", "font"],
                category: .window, symbol: "plus.magnifyingglass", surfaces: [.palette, .keyboard],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.stepAdjust), contextMenuExemption: .stepAdjust)
            ),
            ActionDescriptor(
                id: "home.zoomOut", title: t("action.home.zoomOut", "Chief: Zoom Out"),
                keywords: ["home", "chief", "chat", "zoom", "smaller", "text size", "font"],
                category: .window, symbol: "minus.magnifyingglass", surfaces: [.palette, .keyboard],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.stepAdjust), contextMenuExemption: .stepAdjust)
            ),
            ActionDescriptor(
                id: "home.zoomReset", title: t("action.home.zoomReset", "Chief: Actual Size"),
                keywords: ["home", "chief", "chat", "zoom", "reset", "actual size", "text size"],
                category: .window, symbol: "1.magnifyingglass", surfaces: [.palette, .keyboard],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.stepAdjust), contextMenuExemption: .stepAdjust)
            ),
            // The Home page's conversation list (plans/cmux-next/home-messaging.md):
            // New Message (a DM or a group), Invite, New Chief and Archive Chief.
            // Without arguments the first three open their sheet on the Home page;
            // with them they run headless (`cmux action run`, the CLI verbs).
            ActionDescriptor(
                id: "home.newMessage", title: t("action.home.newMessage", "New Message…"),
                keywords: ["home", "message", "dm", "direct message", "chat", "group", "conversation", "people", "team"],
                category: .window, symbol: "square.and.pencil", surfaces: [.palette, .keyboard, .menu],
                arguments: [ActionArgument(name: "to", title: t("argument.home.message.to", "Person or Email Address"), kind: .string,
                                           isRequired: false),
                            ActionArgument(name: "title", title: t("argument.home.message.title", "Group Name"), kind: .string,
                                           isRequired: false)],
                mainMenu: .file,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            // The New Message draft's x (shown on its list row while the pointer is over it, as in
            // Messages), Escape in an empty To: field, the palette, `cmux home close-new-message`
            // and MCP: one path that discards the draft, its page and its row.
            ActionDescriptor(
                id: "home.closeNewMessage", title: t("action.home.closeNewMessage", "Close New Message"),
                keywords: ["home", "message", "new message", "draft", "close", "discard", "cancel", "compose"],
                category: .window, symbol: "xmark.circle", surfaces: [.palette, .keyboard],
                cliName: "home close-new-message",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "home.invite", title: t("action.home.invite", "Invite to cmux-next…"),
                keywords: ["home", "invite", "email", "people", "team", "message", "join"],
                category: .window, symbol: "person.badge.plus", surfaces: [.palette, .menu],
                arguments: [ActionArgument(name: "email", title: t("argument.home.invite.email", "Email Address"), kind: .string,
                                           isRequired: false)],
                cliName: "home invite", mainMenu: .file,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject, mcpExemption: .credentials)
            ),
            // The active team's email invite (POST /api/teams/:id/invitations), always through its
            // dialog: the Home compose menu and team menu, New Message's To: row for a typed
            // address, the palette and the File menu open it; a CLI or agent run opens it prefilled
            // and waits for the person's Send (a join can bill a seat).
            ActionDescriptor(
                id: "home.inviteToTeam", title: t("action.home.inviteToTeam", "Invite to Team…"),
                keywords: ["home", "team", "invite", "member", "seat", "people", "email", "join", "add"],
                category: .window, symbol: "person.2.badge.plus", surfaces: [.palette, .menu],
                arguments: [ActionArgument(name: "email", title: t("argument.home.invite.email", "Email Address"), kind: .string,
                                           isRequired: false)],
                cliName: "home invite-to-team", mainMenu: .file,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "home.newChief", title: t("action.home.newChief", "New Chief…"),
                keywords: ["home", "chief", "agent", "subchief", "new", "create", "orchestrator"],
                category: .window, symbol: "sparkles", surfaces: [.palette, .menu],
                arguments: [ActionArgument(name: "name", title: t("argument.home.chief.name", "Chief Name"), kind: .string,
                                           isRequired: false),
                            ActionArgument(name: "harness", title: t("argument.home.chief.harness", "Harness"), kind: .string,
                                           isRequired: false),
                            ActionArgument(name: "engine", title: t("argument.home.chief.engine", "Engine"), kind: .string,
                                           isRequired: false)],
                cliName: "home new-chief", mainMenu: .file,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "home.archiveChief", title: t("action.home.archiveChief", "Archive Chief"),
                keywords: ["home", "chief", "archive", "remove", "agent"],
                category: .window, symbol: "archivebox", surfaces: [.keyboard],
                arguments: [chiefArgument],
                cliName: "home archive-chief",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            // The primary Chief: texts to the cmux line go to it (`chief.update {is_default}`); `cmux chief primary` runs it.
            ActionDescriptor(
                id: "home.setPrimaryChief", title: t("action.home.setPrimaryChief", "Make Primary Chief"),
                keywords: ["home", "chief", "primary", "default", "text", "imessage", "sms"],
                category: .window, symbol: "star", surfaces: [.keyboard],
                arguments: [chiefArgument],
                cliName: "home primary-chief",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            // Deleting cannot be undone (Archive Chief can): it asks first.
            ActionDescriptor(
                id: "home.deleteChief", title: t("action.home.deleteChief", "Delete Chief…"),
                keywords: ["home", "chief", "delete", "remove", "agent"],
                category: .window, symbol: "trash", surfaces: [.keyboard],
                arguments: [chiefArgument],
                cliName: "home delete-chief", destructive: true,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            // This Mac's Chief registry, the palette form of `cmux chief edit|engine|adopt` (the owner's
            // `chief.profile.*` and `chief.engine.set`, which the CLI calls itself: ownerVerb).
            // Edit Chief… opens the Chief's editor page (Home's `#/chief/<agent>/edit`).
            ActionDescriptor(
                id: "home.editChief", title: t("action.home.editChief", "Edit Chief…"),
                keywords: ["home", "chief", "edit", "profile", "role", "personality", "instructions", "tools", "backend", "lock"],
                category: .window, symbol: "pencil", surfaces: [.palette, .keyboard],
                arguments: [localChief],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.ownerVerb), contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "home.setChiefModel", title: t("action.home.setChiefModel", "Set Chief Model…"),
                keywords: ["home", "chief", "engine", "model", "backend", "llm"],
                category: .window, symbol: "cpu", surfaces: [.palette, .keyboard],
                arguments: [localChief, ActionArgument(name: "model", title: t("argument.home.chief.model", "Model"), kind: .string)],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.ownerVerb), contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "home.setChiefEffort", title: t("action.home.setChiefEffort", "Set Chief Effort…"),
                keywords: ["home", "chief", "engine", "effort", "reasoning", "thinking"],
                category: .window, symbol: "gauge.with.dots.needle.50percent", surfaces: [.palette, .keyboard],
                arguments: [localChief, ActionArgument(name: "effort", title: t("argument.home.chief.effort", "Effort"), kind: .enumeration([
                    ActionEnumCase(value: "low", title: t("argument.home.chief.effort.low", "Low")),
                    ActionEnumCase(value: "medium", title: t("argument.home.chief.effort.medium", "Medium")),
                    ActionEnumCase(value: "high", title: t("argument.home.chief.effort.high", "High")),
                    ActionEnumCase(value: "xhigh", title: t("argument.home.chief.effort.xhigh", "Extra High")),
                    ActionEnumCase(value: "max", title: t("argument.home.chief.effort.max", "Max")),
                    ActionEnumCase(value: "default", title: t("argument.home.chief.effort.default", "Default")),
                ]))],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.ownerVerb), contextMenuExemption: .noTargetSurface)
            ),
            // An agent of the person's conversations becomes a Chief under its own id; its
            // conversations and history stay (`chief.profile.adopt`, owner only, never a page).
            ActionDescriptor(
                id: "home.adoptChief", title: t("action.home.adoptChief", "Make Agent a Chief…"),
                keywords: ["home", "chief", "adopt", "agent", "promote", "make"],
                category: .window, symbol: "person.badge.plus", surfaces: [.palette, .keyboard],
                arguments: [ActionArgument(name: "agent", title: t("argument.home.chief.agent", "Agent"), kind: .string,
                                           suggestions: ActionSuggestions(source: ActionSuggestions.adoptableAgents, pinned: []))],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.ownerVerb), contextMenuExemption: .noTargetSurface)
            ),
            // On Home the tab keys move through the chat list (Lawrence 2026-10-21): Ctrl-Tab /
            // Ctrl-Shift-Tab, Cmd-Shift-] / [ and Ctrl-1…9, scoped to the Home page and the docked Home
            // (KeyBindingDefaults.homeChatSwitching); a Chief opened as a pane tab keeps the tab keys.
            ActionDescriptor(
                id: "home.previousConversation", title: t("action.home.previousConversation", "Previous Conversation"),
                keywords: ["home", "conversation", "previous", "person", "people", "chief", "up", "cycle", "tab"],
                defaultShortcut: Shortcut("\t", modifiers: [.control, .shift]),
                category: .window, symbol: "chevron.up", surfaces: [.palette, .keyboard, .menu], mainMenu: .view,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.focusMove), contextMenuExemption: .focusMove)
            ),
            ActionDescriptor(
                id: "home.nextConversation", title: t("action.home.nextConversation", "Next Conversation"),
                keywords: ["home", "conversation", "next", "person", "people", "chief", "down", "cycle", "tab"],
                defaultShortcut: Shortcut("\t", modifiers: [.control]),
                category: .window, symbol: "chevron.down", surfaces: [.palette, .keyboard, .menu], mainMenu: .view,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.focusMove), contextMenuExemption: .focusMove)
            ),
            // Ctrl-1…9 on Home: the nth conversation in the list, 9 the last (as Select Tab 1…9).
            ActionDescriptor(
                id: "home.selectConversationByNumber",
                title: t("action.home.selectConversationByNumber", "Select Conversation 1…9"),
                keywords: ["home", "conversation", "chief", "number", "index", "switch", "jump"],
                defaultShortcut: Shortcut("1", modifiers: [.control]), shortcutFamily: .digits,
                category: .window, symbol: "number.square", surfaces: [.keyboard],
                arguments: [CatalogArgument.indexNumber],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.focusMove), contextMenuExemption: .focusMove)
            ),
            ActionDescriptor(
                id: "home.openConversation", title: t("action.home.openConversation", "Open Conversation"),
                keywords: ["home", "conversation", "message", "open", "dm"],
                category: .window, symbol: "bubble.left.and.bubble.right", surfaces: [.keyboard],
                arguments: [ActionArgument(name: "conversation", title: t("argument.home.conversation", "Conversation"), kind: .string)],
                surfacePlan: ActionSurfacePlan(palette: .exempt(.focusMove), cli: .exempt(.focusMove), contextMenuExemption: .focusMove)
            ),
            // Person-to-person DMs and groups (plans/cmux-next/home-dm-group-chats): the group info
            // sheet, the Home row menu and these actions share one path (HomeGroupActions). Each takes
            // `conversation` (an id); without it it acts on the conversation the Home page shows.
            ActionDescriptor(
                id: "home.conversationInfo", title: t("action.home.conversationInfo", "Conversation Info…"),
                keywords: ["home", "group", "info", "details", "members", "people", "dm", "conversation", "mute", "rename"],
                category: .window, symbol: "info.circle", surfaces: [.palette, .keyboard],
                arguments: [Self.conversation],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "home.renameConversation", title: t("action.home.renameConversation", "Rename Group Chat…"),
                keywords: ["home", "group", "rename", "name", "title", "conversation"],
                category: .window, symbol: "pencil", surfaces: [.palette, .keyboard],
                arguments: [Self.conversation,
                            ActionArgument(name: "title", title: t("argument.home.message.title", "Group Name"), kind: .string)],
                cliName: "home rename",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "home.addMembers", title: t("action.home.addMembers", "Add People to Group…"),
                keywords: ["home", "group", "add", "people", "members", "invite", "person", "conversation"],
                category: .window, symbol: "person.badge.plus", surfaces: [.palette, .keyboard],
                arguments: [Self.conversation,
                            ActionArgument(name: "people", title: t("argument.home.groupMembers", "Members"), kind: .string,
                                           suggestions: ActionSuggestions(source: ActionSuggestions.homeMembers, pinned: [],
                                                                          allowsMultiple: true))],
                cliName: "home add-members",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "home.removeMember", title: t("action.home.removeMember", "Remove from Group…"),
                keywords: ["home", "group", "remove", "kick", "member", "person", "conversation"],
                category: .window, symbol: "person.badge.minus", surfaces: [.palette, .keyboard],
                arguments: [Self.conversation,
                            ActionArgument(name: "person", title: t("argument.home.person", "Person"), kind: .string)],
                cliName: "home remove-member",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            // Leaving cannot be undone by me (someone in the group adds me again): it asks first.
            ActionDescriptor(
                id: "home.leaveConversation", title: t("action.home.leaveConversation", "Leave Group…"),
                keywords: ["home", "group", "leave", "exit", "quit", "conversation"],
                category: .window, symbol: "rectangle.portrait.and.arrow.right", surfaces: [.palette, .keyboard],
                arguments: [Self.conversation],
                cliName: "home leave", destructive: true,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "home.muteConversation", title: t("action.home.muteConversation", "Hide Alerts"),
                keywords: ["home", "mute", "hide alerts", "notifications", "silence", "group", "dm", "conversation"],
                category: .window, symbol: "bell.slash", surfaces: [.palette, .keyboard],
                arguments: [Self.conversation],
                cliName: "home mute",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "home.unmuteConversation", title: t("action.home.unmuteConversation", "Show Alerts"),
                keywords: ["home", "unmute", "show alerts", "notifications", "group", "dm", "conversation"],
                category: .window, symbol: "bell", surfaces: [.palette, .keyboard],
                arguments: [Self.conversation],
                cliName: "home unmute",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            // Group chats with Chiefs (plans/cmux-next/chief-group-chats-DESIGN.md): `cmux chat create
            // --members "Chief, Unii, aziz@manaflow.com" [--title T] [--replies auto|mentions|all]`
            // makes the group New Message makes; `cmux chat replies` sets when its Chiefs answer.
            ActionDescriptor(
                id: "home.createGroup", title: t("action.home.createGroup", "New Group Chat…"),
                keywords: ["home", "group", "chat", "chief", "chiefs", "agents", "people", "new", "create", "imessage", "conversation"],
                category: .window, symbol: "person.3", surfaces: [.palette, .keyboard],
                arguments: [ActionArgument(name: "members", title: t("argument.home.groupMembers", "Members"), kind: .string,
                                           suggestions: ActionSuggestions(source: ActionSuggestions.homeMembers, pinned: [],
                                                                          allowsMultiple: true)),
                            ActionArgument(name: "title", title: t("argument.home.message.title", "Group Name"), kind: .string,
                                           isRequired: false),
                            Self.replies(isRequired: false)],
                cliName: "chat create",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // Chief channels (plans/cmux-next/chief-channels-DESIGN.md): `cmux chat channel create --title T
            // [--members "Leo, ana@example.com"] [--chief NAME]` makes a group the person owns with its own
            // Chief scoped to it, and invites the members (an email gets an invite).
            ActionDescriptor(
                id: "home.createChannel", title: t("action.home.createChannel", "New Channel…"),
                keywords: ["home", "channel", "channels", "chief", "team", "group", "room", "slack", "new", "create", "invite"],
                category: .window, symbol: "number", surfaces: [.palette, .keyboard],
                arguments: [ActionArgument(name: "title", title: t("argument.home.channelTitle", "Channel Name"), kind: .string),
                            ActionArgument(name: "members", title: t("argument.home.groupMembers", "Members"), kind: .string,
                                           isRequired: false,
                                           suggestions: ActionSuggestions(source: ActionSuggestions.homeMembers, pinned: [],
                                                                          allowsMultiple: true)),
                            ActionArgument(name: "chief", title: t("argument.home.channelChief", "Chief Name"), kind: .string,
                                           isRequired: false)],
                cliName: "chat channel create",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "home.setChiefReplies", title: t("action.home.setChiefReplies", "Set When Chiefs Reply…"),
                keywords: ["home", "group", "chief", "chiefs", "reply", "replies", "wake", "mention", "every message", "conversation"],
                category: .window, symbol: "bubble.left.and.text.bubble.right", surfaces: [.palette, .keyboard],
                arguments: [Self.conversation, Self.replies(isRequired: true)],
                cliName: "chat replies",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            // Pin or unpin a conversation in the Home sidebar's pinned grid (pinning-DESIGN.md): the
            // row's Pin/Unpin, a tile dragged out of the grid, the palette, `cmux home pin-unpin` and
            // MCP run it. `pinned` sets the state; without it the action toggles.
            ActionDescriptor(
                id: "home.togglePin", title: t("action.home.togglePin", "Pin/Unpin Conversation"),
                keywords: ["home", "pin", "unpin", "pinned", "favorite", "top", "conversation", "chief", "dm", "group"],
                category: .window, symbol: "pin", surfaces: [.palette, .keyboard],
                arguments: [Self.conversation,
                            ActionArgument(name: "pinned", title: t("argument.home.pinned", "Pinned"), kind: .bool, isRequired: false)],
                cliName: "home pin-unpin",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            // Delete a conversation from the Home list, as Messages' Delete Conversation (user 2026-10-29):
            // the row's Delete Conversation…, its left swipe, the palette, `cmux home hide` and MCP. It
            // only leaves this account's list (the conversation stays with its owner); a newer message
            // lists it again, and Show Hidden Conversations lists every one again.
            ActionDescriptor(
                id: "home.hideConversation", title: t("action.home.hideConversation", "Delete Conversation from List"),
                keywords: ["home", "delete", "hide", "remove", "clear", "archive", "conversation", "chat", "dm", "group", "chief"],
                category: .window, symbol: "trash", surfaces: [.palette, .keyboard],
                arguments: [Self.conversation],
                cliName: "home hide",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "home.showHiddenConversations", title: t("action.home.showHiddenConversations", "Show Hidden Conversations"),
                keywords: ["home", "unhide", "restore", "deleted", "hidden", "recently deleted", "conversation", "chat"],
                category: .window, symbol: "eye", surfaces: [.palette, .keyboard],
                cliName: "home show-hidden",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // A chat's own bubble and text colours (user 2026-10-28): the row's Chat Colors… and the
            // palette open the picker; `cmux chat colors --conversation <id> --sent "#34C759"` sets one
            // (`default` clears a role, `--reset` clears them all). Looks only, kept on this Mac.
            ActionDescriptor(
                id: "home.chatColors", title: t("action.home.chatColors", "Chat Colors…"),
                keywords: ["home", "chat", "colors", "colours", "bubble", "text", "background", "theme", "imessage", "conversation"],
                category: .window, symbol: "paintpalette", surfaces: [.palette, .keyboard],
                arguments: [Self.conversation,
                            Self.color("sent", t("argument.home.chatColors.sent", "My Bubble Color")),
                            Self.color("sentText", t("argument.home.chatColors.sentText", "My Text Color")),
                            Self.color("received", t("argument.home.chatColors.received", "Their Bubble Color")),
                            Self.color("receivedText", t("argument.home.chatColors.receivedText", "Their Text Color")),
                            ActionArgument(name: "reset", title: t("argument.home.chatColors.reset", "Reset to Default"), kind: .bool,
                                           isRequired: false)],
                cliName: "chat colors",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            // `cmux home send --conversation <id> --text "…"`: a message as me, in a DM or group.
            ActionDescriptor(
                id: "home.sendMessage", title: t("action.home.sendMessage", "Send Message…"),
                keywords: ["home", "send", "message", "text", "dm", "group", "chat", "conversation"],
                category: .window, symbol: "paperplane", surfaces: [.palette, .keyboard],
                arguments: [Self.conversation,
                            ActionArgument(name: "text", title: t("argument.home.send.text", "Message"), kind: .string)],
                cliName: "home send",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            // Stop all agents (coordinator 2026-10-20): the Chief's turn and every
            // subagent (chief.stop {all}); a plain stop never stops a subagent.
            // Option-click on the compose bar's stop button runs it too; its
            // toast lists what stopped and offers Restart.
            ActionDescriptor(
                id: "home.stopAllAgents",
                title: String(localized: "action.home.stopAllAgents", defaultValue: "Stop All Agents", bundle: .module),
                keywords: ["chief", "home", "stop", "all", "agents", "subagents", "cancel"], category: .agents,
                symbol: "stop.circle.fill", surfaces: [.palette, .menu], mainMenu: .file,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            // Start now on an agent the Chief queued behind its cap (user 2026-11-08): the agent
            // pill's context menu, the palette, `cmux home start-agent --agent <name>` and MCP ask the
            // Chief of the Chief Home showing `conversation` (the key window's without one) to start it
            // past the cap. The pill's menu is MessagesLab's own, with no ContextMenuCatalog placement:
            // the Home takes this row from `makeContextMenuItem` (HomeChiefTurnActions.swift), and
            // HomeChiefHomes binds the handler.
            ActionDescriptor(
                id: "home.startQueuedAgent", title: t("action.home.startQueuedAgent", "Start Queued Agent Now"),
                keywords: ["chief", "home", "agent", "subagent", "queue", "queued", "waiting", "start", "now", "cap"],
                category: .agents, symbol: "play.circle", surfaces: [.palette, .keyboard],
                arguments: [ActionArgument(name: "agent", title: String(localized: "argument.newTab.agent", defaultValue: "Agent",
                                                                        table: "NewTabActions", bundle: .module), kind: .string),
                            Self.conversation],
                cliName: "home start-agent",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            // DEV and NIGHTLY: MessagesLab's flight recorder writes the last ~10 s of the
            // Home transcript to ~/Library/Logs/<app>/blink-<time>/ (Debug menu, palette).
            ActionDescriptor(
                id: "home.saveFlightRecording", title: t("action.home.saveFlightRecording", "Save Last 10 Seconds"),
                keywords: ["home", "flight recorder", "blink", "debug", "record", "dump", "messages"],
                category: .window, symbol: "record.circle", surfaces: [.palette, .menu], mainMenu: .debug, isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
        ]
    }

    /// DEV builds only: Debug > Agent Messages Playground (the agent-message header variants live in the
    /// real Home transcript, user 2026-11-02). `style` picks a variant (0: the shipped look), `expanded`
    /// opens the folds, `team` shows a chat with a teammate, `peer` clicks that agent's pill, `dark` picks the
    /// dark look.
    private static var debugOnly: [ActionDescriptor] {
        #if DEBUG
        [
            ActionDescriptor(
                id: "home.agentMessagePlayground", title: t("action.home.agentMessagePlayground", "Agent Messages Playground"),
                keywords: ["home", "chief", "agent", "messages", "playground", "variants", "header", "fold", "debug"],
                category: .window, symbol: "square.stack.3d.up", surfaces: [.palette, .menu],
                arguments: [
                    ActionArgument(name: "style", title: t("argument.home.playgroundStyle", "Header Style"), kind: .int(0...32), isRequired: false),
                    ActionArgument(name: "expanded", title: t("argument.home.playgroundExpanded", "Expanded"), kind: .bool, isRequired: false),
                    ActionArgument(name: "team", title: t("argument.home.playgroundTeam", "Team Chat"), kind: .bool, isRequired: false),
                    ActionArgument(name: "peer", title: t("argument.home.playgroundPeer", "Agent"), kind: .string, isRequired: false),
                    ActionArgument(name: "dark", title: t("argument.home.playgroundDark", "Dark Look"), kind: .bool, isRequired: false),
                ],
                mainMenu: .debug, isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
            // Debug > MCP Connect Card Playground (plans/cmux-next/mcp-connect-DESIGN.md section 8): the card's
            // styles for each kind of server, in each phase, light and dark.
            ActionDescriptor(
                id: "home.mcpConnectPlayground", title: t("action.home.mcpConnectPlayground", "MCP Connect Card Playground"),
                keywords: ["home", "chief", "mcp", "connect", "server", "card", "playground", "variants", "debug"],
                category: .window, symbol: "square.stack.3d.up", surfaces: [.palette, .menu],
                arguments: [
                    ActionArgument(name: "style", title: t("argument.home.mcpPlaygroundStyle", "Card Style"), kind: .int(1...6), isRequired: false),
                    ActionArgument(name: "fixture", title: t("argument.home.mcpPlaygroundServer", "Server"), kind: .int(0...5), isRequired: false),
                    ActionArgument(name: "phase", title: t("argument.home.mcpPlaygroundPhase", "Phase"), kind: .int(0...6), isRequired: false),
                ],
                mainMenu: .debug, isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
            // Debug > Before/After Table Playground (the user, 2026-11-05): seven live ways to show a Before|After ×
            // Light|Dark table of pictures (slider, toggle, onion skin, synced zoom, filmstrip, the chat card's
            // large pairs and grid).
            ActionDescriptor(
                id: "home.compareTablePlayground", title: t("action.home.compareTablePlayground", "Before/After Table Playground"),
                keywords: ["home", "chief", "table", "before", "after", "compare", "slider", "pictures", "playground", "variants", "debug"],
                category: .window, symbol: "rectangle.split.2x1", surfaces: [.palette, .menu],
                arguments: [
                    ActionArgument(name: "variant", title: t("argument.home.comparePlaygroundVariant", "Variant"), kind: .int(1...7), isRequired: false),
                    ActionArgument(name: "row", title: t("argument.home.comparePlaygroundRow", "Picture Set"), kind: .int(0...1), isRequired: false),
                    ActionArgument(name: "dark", title: t("argument.home.playgroundDark", "Dark Look"), kind: .bool, isRequired: false),
                ],
                mainMenu: .debug, isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
            // Debug > Chief Teleport Playground: the Chief's location chip variants in every state
            // (This Mac, cmux Cloud, a Mac mini, moving, failed, rolled back, a CLI move, a fork), light and dark.
            ActionDescriptor(
                id: "home.chiefTeleportPlayground", title: t("action.home.chiefTeleportPlayground", "Chief Teleport Playground"),
                keywords: ["home", "chief", "teleport", "move", "location", "cloud", "mac mini", "playground", "variants", "debug"],
                category: .window, symbol: "location.circle", surfaces: [.palette, .menu],
                arguments: [
                    ActionArgument(name: "state", title: t("argument.home.teleportPlaygroundState", "Menu State"), kind: .int(0...9), isRequired: false),
                ],
                mainMenu: .debug, isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
        ]
        #else
        []
        #endif
    }

    /// When a group's Chiefs answer: `auto` (the default), `mentions` or `all`.
    private static func replies(isRequired: Bool) -> ActionArgument {
        ActionArgument(name: "replies", title: t("argument.home.replies", "Chiefs Reply"),
                       kind: .enumeration([ActionEnumCase(value: "auto", title: t("argument.home.replies.auto", "Automatically")),
                                           ActionEnumCase(value: "mentions", title: t("argument.home.replies.mentions", "Only When @Mentioned")),
                                           ActionEnumCase(value: "all", title: t("argument.home.replies.all", "To Every Message"))]),
                       isRequired: isRequired)
    }

    /// One bubble colour of `home.chatColors`: `#RRGGBB`, or `default` for the default for every chat.
    private static func color(_ name: String, _ title: String) -> ActionArgument {
        ActionArgument(name: name, title: title, kind: .string, isRequired: false)
    }

    /// The conversation a group action acts on (an id); without it, the one Home shows.
    private static var conversation: ActionArgument {
        ActionArgument(name: "conversation", title: t("argument.home.conversation", "Conversation"), kind: .string, isRequired: false)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "HomeActions", bundle: .module)
    }
}
