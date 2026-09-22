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
        if let requested = normalized(requested, preserveExact: preserveExact) {
            return requested
        }
        if let rescued {
            return rescued
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
        return TerminalWorkingDirectoryResolver.firstAvailable(candidates)
    }
}
