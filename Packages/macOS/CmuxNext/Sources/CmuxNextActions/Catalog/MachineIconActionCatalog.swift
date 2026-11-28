// Machine icons (`session-icon-v1`, cx-qno.11.4): the icon a machine's sidebar
// header, its workspaces' hover cards and the machine pickers draw, kept on
// the machine's record in the home daemon's session registry. One path for
// every machine header's menu, the palette, the CLI (`cmux machine set-icon`)
// and MCP: an `icon` argument sets it; without one the shared icon picker
// opens at the machine's header. Titles live in Localizable.xcstrings.

nonisolated enum MachineIconActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "machine.setIcon",
                title: String(localized: "action.machine.setIcon", defaultValue: "Set Machine Icon…", bundle: .module),
                keywords: ["machine", "computer", "host", "icon", "emoji", "symbol"], category: .sidebar, symbol: "face.smiling",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.iconString.optional], targets: [.machine],
                cliName: "machine set-icon"
            ),
            ActionDescriptor(
                id: "machine.clearIcon",
                title: String(localized: "action.machine.clearIcon", defaultValue: "Remove Machine Icon", bundle: .module),
                keywords: ["machine", "computer", "host", "icon", "emoji", "reset"], category: .sidebar, symbol: "xmark.circle",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "machine clear-icon"
            ),
        ]
    }
}
