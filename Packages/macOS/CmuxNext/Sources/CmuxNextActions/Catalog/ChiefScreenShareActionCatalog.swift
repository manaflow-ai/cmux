// Share Screen with Chief (docs/chief-screen-share.md): the person shares this Mac's screen with
// their Chief, which keeps what changed as memory notes and can look now. The Home header toggle,
// the palette, the CLI (`cmux chief ...`) and MCP run these. Only the person starts sharing: start
// and toggle are person-only (the control socket refuses them whatever origin a script claims, so
// no terminal agent turns on capture of the person's screen) and no MCP tool; stop and look are
// offered everywhere. Titles live in ActionCatalog.xcstrings.

nonisolated enum ChiefScreenShareActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let keywords = ["chief", "screen", "share", "sharing", "capture", "see", "memory", "record"]
        return [
            personOnly(ActionDescriptor(
                id: "chief.screenShare.toggle", title: t("action.chief.screenShare.toggle", "Chief: Toggle Screen Sharing"),
                keywords: keywords + ["toggle"], category: .agents, symbol: "display", surfaces: [.palette],
                cliName: "chief toggle-screen-share",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject, mcpExemption: .systemChange)
            )),
            personOnly(ActionDescriptor(
                id: "chief.screenShare.start", title: t("action.chief.screenShare.start", "Share Screen with Chief"),
                keywords: keywords + ["start"], category: .agents, symbol: "display", surfaces: [.palette],
                cliName: "chief share-screen",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject, mcpExemption: .systemChange)
            )),
            ActionDescriptor(
                id: "chief.screenShare.stop", title: t("action.chief.screenShare.stop", "Stop Sharing Screen with Chief"),
                keywords: keywords + ["stop", "end"], category: .agents, symbol: "stop.circle", surfaces: [.palette],
                cliName: "chief stop-sharing-screen",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "chief.screenShare.look", title: t("action.chief.screenShare.look", "Chief: Look at Screen Now"),
                keywords: keywords + ["look", "now", "screenshot"], category: .agents, symbol: "eye", surfaces: [.palette],
                cliName: "chief look-at-screen",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
        ]
    }

    /// Capture of the person's screen starts only from the person's own gesture.
    private static func personOnly(_ descriptor: ActionDescriptor) -> ActionDescriptor {
        var descriptor = descriptor
        descriptor.isPersonOnly = true
        return descriptor
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "ActionCatalog", bundle: .module)
    }
}
