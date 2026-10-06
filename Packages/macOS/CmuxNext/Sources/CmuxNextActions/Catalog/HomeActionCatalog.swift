// Home (plans/cmux-next/home.md): the pinned sidebar row that shows the native
// conversations screen. Cmd+1 reaches it through `selectWorkspaceByNumber`
// (digit 1); this action is the palette, menu and CLI path.
// `home.attachFiles` is the one action behind the composer's attach button:
// the palette opens the file picker; `cmux home attach <path>` hands a file to
// the shown Home composer through the same intake as a drop.

nonisolated enum HomeActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "home.show",
                title: String(localized: "action.home.show", defaultValue: "Go to Home", bundle: .module),
                keywords: ["home", "mux", "messages", "conversations", "orchestrator"], category: .window, symbol: "house",
                surfaces: [.palette, .keyboard, .menu], cliName: "home show",
                mainMenu: .file
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
