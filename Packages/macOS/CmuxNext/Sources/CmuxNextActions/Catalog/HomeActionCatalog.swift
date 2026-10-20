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
        let waits: Set<ActionID> = ["home.newMessage", "home.invite", "home.newChief", "home.archiveChief"]
        return all.map { descriptor in
            var descriptor = descriptor
            descriptor.waitsForResult = waits.contains(descriptor.id)
            return descriptor
        }
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
            ActionDescriptor(
                id: "home.attachFiles", title: t("action.home.attachFiles", "Attach Files…"),
                keywords: ["home", "attach", "file", "photo", "video", "image", "upload", "message", "conversation"],
                category: .window, symbol: "paperclip", surfaces: [.palette, .keyboard],
                arguments: [ActionArgument(name: "path", title: t("argument.home.attach.path", "File Path"), kind: .string,
                                           isRequired: false)],
                cliName: "home attach",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
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
            ActionDescriptor(
                id: "home.invite", title: t("action.home.invite", "Invite to cmux-next…"),
                keywords: ["home", "invite", "email", "people", "team", "message", "join"],
                category: .window, symbol: "person.badge.plus", surfaces: [.palette, .menu],
                arguments: [ActionArgument(name: "email", title: t("argument.home.invite.email", "Email Address"), kind: .string,
                                           isRequired: false)],
                cliName: "home invite", mainMenu: .file,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject, mcpExemption: .credentials)
            ),
            ActionDescriptor(
                id: "home.newChief", title: t("action.home.newChief", "New Chief…"),
                keywords: ["home", "chief", "agent", "subchief", "new", "create", "orchestrator"],
                category: .window, symbol: "sparkles", surfaces: [.palette, .menu],
                arguments: [ActionArgument(name: "name", title: t("argument.home.chief.name", "Chief Name"), kind: .string,
                                           isRequired: false)],
                cliName: "home new-chief", mainMenu: .file,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "home.archiveChief", title: t("action.home.archiveChief", "Archive Chief"),
                keywords: ["home", "chief", "archive", "remove", "agent"],
                category: .window, symbol: "archivebox", surfaces: [.keyboard],
                arguments: [ActionArgument(name: "chief", title: t("argument.home.chief.id", "Chief"), kind: .string)],
                cliName: "home archive-chief",
                surfacePlan: ActionSurfacePlan(palette: .exempt(.noTargetSurface), cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            // No keys: Cmd-Shift-[ / ] are Chrome tab keys everywhere, Home too (KeyBindingDefaults.tabSwitching).
            ActionDescriptor(
                id: "home.previousConversation", title: t("action.home.previousConversation", "Previous Conversation"),
                keywords: ["home", "conversation", "previous", "person", "people", "chief", "up"],
                category: .window, symbol: "chevron.up", surfaces: [.palette, .keyboard, .menu], mainMenu: .view,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.focusMove), contextMenuExemption: .focusMove)
            ),
            ActionDescriptor(
                id: "home.nextConversation", title: t("action.home.nextConversation", "Next Conversation"),
                keywords: ["home", "conversation", "next", "person", "people", "chief", "down"],
                category: .window, symbol: "chevron.down", surfaces: [.palette, .keyboard, .menu], mainMenu: .view,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.focusMove), contextMenuExemption: .focusMove)
            ),
            ActionDescriptor(
                id: "home.openConversation", title: t("action.home.openConversation", "Open Conversation"),
                keywords: ["home", "conversation", "message", "open", "dm"],
                category: .window, symbol: "bubble.left.and.bubble.right", surfaces: [.keyboard],
                arguments: [ActionArgument(name: "conversation", title: t("argument.home.conversation", "Conversation"), kind: .string)],
                surfacePlan: ActionSurfacePlan(palette: .exempt(.focusMove), cli: .exempt(.focusMove), contextMenuExemption: .focusMove)
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

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "HomeActions", bundle: .module)
    }
}
