// Catalog rows for resource usage (hover-card CPU and memory). Titles live
// in Localizable.xcstrings. The numbers are the `resources` control method.

nonisolated enum ResourceActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "tab.showResources",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.tab.showResources") + "\u{E002}" + String(localized: "action.tab.showResources", defaultValue: "Show Tab Resource Usage", bundle: .module)),
                keywords: ["cpu", "memory", "ram", "process", "activity", "task manager", "usage"], category: .tab,
                symbol: "gauge.with.dots.needle.33percent", surfaces: [.palette, .contextMenu],
                targets: [.tab], cliName: "tab show-resources"
            ),
            ActionDescriptor(
                id: "workspace.showResources",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.workspace.showResources") + "\u{E002}" + String(localized: "action.workspace.showResources", defaultValue: "Show Workspace Resource Usage", bundle: .module)),
                keywords: ["cpu", "memory", "ram", "process", "activity", "task manager", "usage"], category: .workspace,
                symbol: "gauge.with.dots.needle.33percent", surfaces: [.palette, .contextMenu],
                targets: [.workspace], cliName: "workspace show-resources"
            ),
        ]
    }
}
