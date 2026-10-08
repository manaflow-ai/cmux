// SSH machines: machines reached over the user's own OpenSSH, each a
// cmux-tui session in the sidebar (plans/cmux-next/data-model.md 1.1).
// Titles live in RemoteActions.xcstrings.

nonisolated enum RemoteActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "remote.connect",
                title: String(localized: "action.remote.connect", defaultValue: "Connect to Machine…", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "host", "server", "machine", "cmux-tui"], category: .remote, symbol: "server.rack",
                surfaces: [.palette, .menu, .contextMenu],
                arguments: [CatalogArgument.destinationString, CatalogArgument.sessionString, CatalogArgument.binaryString,
                            CatalogArgument.stateDirString],
                cliName: "remote connect", mainMenu: .file
            ),
            ActionDescriptor(
                id: "remote.newWorkspace",
                title: String(localized: "action.remote.newWorkspace", defaultValue: "New Workspace on Machine", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "host", "terminal"], category: .remote, symbol: "plus.rectangle.on.rectangle",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "remote new-workspace", startsTerminal: true
            ),
            ActionDescriptor(
                id: "remote.openTerminalHere",
                title: String(localized: "action.remote.openTerminalHere", defaultValue: "Open Terminal on Machine Here…", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "machine", "session", "terminal", "mixed"], category: .remote, symbol: "terminal",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [CatalogArgument.machineMachine], targets: [.pane],
                cliName: "remote open-terminal-here", startsTerminal: true
            ),
            ActionDescriptor(
                id: "remote.reconnect",
                title: String(localized: "action.remote.reconnect", defaultValue: "Reconnect Machine", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "retry"], category: .remote, symbol: "arrow.clockwise",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "remote reconnect"
            ),
            ActionDescriptor(
                id: "remote.disconnect",
                title: String(localized: "action.remote.disconnect", defaultValue: "Disconnect Machine", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "offline"], category: .remote, symbol: "bolt.horizontal.circle",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "remote disconnect"
            ),
            ActionDescriptor(
                id: "remote.install",
                title: String(localized: "action.remote.install", defaultValue: "Install cmux-tui on Machine…", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "update", "upgrade", "cmux-tui"], category: .remote, symbol: "arrow.down.circle",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "remote install", destructive: true
            ),
            ActionDescriptor(
                id: "remote.forget",
                title: String(localized: "action.remote.forget", defaultValue: "Forget Machine…", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "remove", "delete"], category: .remote, symbol: "trash",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "remote forget", destructive: true
            ),
            // DEV and NIGHTLY only: a remote browser tab (remote-tab.md r2)
            // from a loopback rb/1 host such as cmux-remote-browser-testhost.
            // Scripts reach it through `action.run`, the same path.
            ActionDescriptor(
                id: "remote.openBrowserTab",
                title: String(localized: "action.remote.openBrowserTab", defaultValue: "Open Remote Browser Tab", table: "RemoteActions", bundle: .module),
                keywords: ["remote", "browser", "tab", "rb", "stream", "chromium", "host"], category: .remote, symbol: "globe",
                surfaces: [.palette],
                arguments: [ActionArgument(
                    name: "address",
                    title: String(localized: "argument.remote.hostAddress", defaultValue: "Host Address", table: "RemoteActions", bundle: .module),
                    kind: .string)],
                isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
            // DEV only: starts this build's remote browser host on a free
            // loopback port and opens a remote tab to it; closing the tab
            // stops the host (RemoteBrowserPages.openLocal).
            ActionDescriptor(
                id: "remote.openLocalBrowserTab",
                title: String(localized: "action.remote.openLocalBrowserTab", defaultValue: "Open Remote Browser Tab (Local Host)", table: "RemoteActions", bundle: .module),
                keywords: ["remote", "browser", "tab", "rb", "stream", "chromium", "host", "local", "loopback"], category: .remote, symbol: "globe",
                surfaces: [.palette],
                isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
        ]
    }
}
