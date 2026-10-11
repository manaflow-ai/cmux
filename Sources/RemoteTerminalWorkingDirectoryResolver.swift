import Foundation

enum RemoteTerminalWorkingDirectoryResolver {
    static func normalized(_ workingDirectory: String?, preserveExact: Bool) -> String? {
        guard let workingDirectory else { return nil }
        if preserveExact {
            return workingDirectory.isEmpty ? nil : workingDirectory
        }
        return TerminalWorkingDirectoryResolver.normalized(workingDirectory)
    }

    static func resolve(
        requested: String?,
        preserveExact: Bool,
        rescued: String?,
        panelDirectory: String?,
        requestedPanelDirectory: String?,
        remoteInitialDirectory: String?,
        currentDirectory: String?
    ) -> String? {
        if preserveExact {
            if let requested = normalized(requested, preserveExact: true) { return requested }
            if let rescued = normalized(rescued, preserveExact: true) { return rescued }
        } else {
            // A deleted local worktree must never fall through to the
            // selected workspace's directory. Keep the restore in the saved
            // path's ancestry, where a resumed agent cannot silently target a
            // different repository.
            if let requested = normalized(requested, preserveExact: false),
               nearestExistingDirectory(requested) == requested {
                return requested
            }
            if let rescued = nearestExistingDirectory(rescued) { return rescued }
            if let requested = nearestExistingDirectory(requested) { return requested }
        }
        let candidates = [
            panelDirectory,
            requestedPanelDirectory,
            remoteInitialDirectory,
            currentDirectory,
        ]
        if preserveExact {
            return candidates.lazy.compactMap { normalized($0, preserveExact: true) }.first
        }
        if let candidate = candidates.lazy.compactMap(nearestExistingDirectory).first {
            return candidate
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static func nearestExistingDirectory(_ value: String?) -> String? {
        guard let normalized = normalized(value, preserveExact: false) else { return nil }
        var url = URL(fileURLWithPath: normalized, isDirectory: true)
        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return nil }
            url = parent
        }
    }
}
