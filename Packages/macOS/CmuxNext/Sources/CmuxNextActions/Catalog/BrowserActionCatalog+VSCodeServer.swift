// Browser actions that stop and restart the VS Code inline server.

nonisolated extension BrowserActionCatalog {
    static func vscodeServerDescriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "palette.vscodeServeWebStop",
                title: String(localized: "action.palette.vscodeServeWebStop", defaultValue: "Stop VS Code Inline Server", bundle: .module),
                keywords: ["vscode", "editor", "server"], category: .browser, symbol: "stop.fill", surfaces: [.palette],
                targets: [.pane], cliName: "browser stop-vs-code-inline-server"
            ),
            ActionDescriptor(
                id: "palette.vscodeServeWebRestart",
                title: String(localized: "action.palette.vscodeServeWebRestart", defaultValue: "Restart VS Code Inline Server", bundle: .module),
                keywords: ["vscode", "editor", "server"], category: .browser, symbol: "arrow.clockwise.circle",
                surfaces: [.palette], targets: [.pane], cliName: "browser restart-vs-code-inline-server"
            ),
        ]
    }
}
