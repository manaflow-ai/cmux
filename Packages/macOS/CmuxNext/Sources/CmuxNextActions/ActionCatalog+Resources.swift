// Catalog rows for resource usage (hover-card CPU and memory). Titles live
// in Localizable.xcstrings. The numbers are the `resources` control method.

extension ActionCatalog {
    static func resourceActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "tab.showResources",
                title: String(localized: "action.tab.showResources", defaultValue: "Show Tab Resource Usage", bundle: .module),
                keywords: ["cpu", "memory", "ram", "process", "activity", "task manager", "usage"], category: .tab,
                symbol: "gauge.with.dots.needle.33percent", surfaces: [.palette, .contextMenu],
                targets: [.tab], cliName: "tab show-resources"
            ),
            ActionDescriptor(
                id: "workspace.showResources",
                title: String(localized: "action.workspace.showResources", defaultValue: "Show Workspace Resource Usage", bundle: .module),
                keywords: ["cpu", "memory", "ram", "process", "activity", "task manager", "usage"], category: .workspace,
                symbol: "gauge.with.dots.needle.33percent", surfaces: [.palette, .contextMenu],
                targets: [.workspace], cliName: "workspace show-resources"
            ),
        ]
    }
}
