// cmux:// links (the deep links contract): one action, `link.open`, opens a
// `DeepLink`, and every entrypoint goes through it (the OS URL handler, the
// palette, `cmux link open <url>`, MCP). It only navigates. The Copy Link
// actions live with their objects (`palette.copyWorkspaceLink`,
// `palette.copyPaneLink`, `palette.copySurfaceLink`).

nonisolated enum LinkActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "link.open",
                title: String(localized: "action.link.open", defaultValue: "Open Link…", bundle: .module),
                keywords: ["link", "url", "deeplink", "cmux://", "go to", "jump", "paste"],
                category: .window, symbol: "link", surfaces: [.palette, .keyboard],
                arguments: [
                    ActionArgument(name: "url", title: String(localized: "argument.link.url", defaultValue: "Link", bundle: .module),
                                   kind: .string),
                    ActionArgument(name: "background",
                                   title: String(localized: "argument.link.background", defaultValue: "Open in Background", bundle: .module),
                                   kind: .bool, isRequired: false),
                ],
                cliName: "link open",
                // A link names its own target, so there is no object to
                // right-click; the CLI and MCP take the URL.
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
        ]
    }
}
