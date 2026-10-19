import Foundation

extension CloudTreeTerminalRow {
    var directoryText: String? {
        guard !resource.machine.isLocal else {
            return resource.detail.flatMap { $0.isEmpty ? nil : CloudTreeTerminalRowContent.abbreviated($0) }
        }
        // `resourceForPresentation` removes unconfirmed paths before the row is built. A stale
        // row may therefore safely retain the last accepted remote cwd; freshness alone must not
        // replace that known path with the unavailable placeholder.
        guard let path = resource.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return CloudWorkspaceSidebarPresentation.unavailableDirectory
        }
        // A remote absolute path must never be shortened against the Mac's HOME.
        return path
    }

    var directoryHelp: String? {
        guard let id = resource.machine.cloudMachineID else { return resource.detail }
        let name = machineDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id
        let identity = name.isEmpty || name == id ? id : "\(name) (\(id))"
        return "\(identity)\n\(directoryText ?? CloudWorkspaceSidebarPresentation.unavailableDirectory)"
    }
}
