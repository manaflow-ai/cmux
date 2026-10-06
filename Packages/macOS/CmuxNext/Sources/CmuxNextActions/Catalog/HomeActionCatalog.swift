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
