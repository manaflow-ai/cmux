// SSH machines: machines reached over the user's own OpenSSH, each a
// cmux-tui session in the sidebar (plans/cmux-next/data-model.md 1.1).
// Titles live in RemoteActions.xcstrings.

nonisolated extension ActionCatalog {
    static func remoteActions() -> [ActionDescriptor] {
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
        ]
    }
}
