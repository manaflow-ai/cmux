import Foundation

// Ghostty's argv-based shell integration (`terminal-shell-args-v1`):
// `DaemonConnection.request` applies it to every terminal-creating request.

/// A request that starts a terminal running the user's shell, which may get
/// Ghostty's argv-based shell integration (`terminal-shell-args-v1`).
/// `DaemonConnection.request` applies it when the daemon serves the
/// capability, so every creation path (tabs, splits, columns, workspaces,
/// the compat CLI) gets the same shell.
protocol ShellIntegrationArgumentCarrying {
    func addingShellIntegrationArguments() -> Self
}

extension NewTabRequest: ShellIntegrationArgumentCarrying {
    func addingShellIntegrationArguments() -> Self {
        var request = self
        request.options = options.addingShellIntegrationArguments()
        return request
    }
}

extension SpawnOptions {
    /// These options with Ghostty's shell-integration arguments for the
    /// shell in `env`, unless the caller chose the program.
    func addingShellIntegrationArguments() -> SpawnOptions {
        guard argv == nil, command == nil, shellArgs == nil, let env else { return self }
        var options = self
        options.shellArgs = GhosttyShellIntegration.shellArguments(for: env)
        return options
    }
}

extension SplitRequest: ShellIntegrationArgumentCarrying {
    func addingShellIntegrationArguments() -> Self {
        var request = self
        request.options = options.addingShellIntegrationArguments()
        return request
    }
}

extension NewPaneRequest: ShellIntegrationArgumentCarrying {
    func addingShellIntegrationArguments() -> Self {
        var request = self
        request.options = options.addingShellIntegrationArguments()
        return request
    }
}

extension NewColumnRequest: ShellIntegrationArgumentCarrying {
    func addingShellIntegrationArguments() -> Self {
        var request = self
        request.options = options.addingShellIntegrationArguments()
        return request
    }
}

extension CreateTerminalRequest: ShellIntegrationArgumentCarrying {
    func addingShellIntegrationArguments() -> Self {
        guard argv == nil, command == nil, shellArgs == nil, let env else { return self }
        var request = self
        request.shellArgs = GhosttyShellIntegration.shellArguments(for: env)
        return request
    }
}

extension MoveTabToSplitRespawnRequest: ShellIntegrationArgumentCarrying {
    func addingShellIntegrationArguments() -> Self {
        guard case .terminal(let options) = respawn else { return self }
        var request = self
        request.respawn = .terminal(options.addingShellIntegrationArguments())
        return request
    }
}
