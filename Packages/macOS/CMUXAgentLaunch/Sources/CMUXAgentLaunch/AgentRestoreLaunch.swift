import Foundation

/// Describes one cmux-owned managed-agent session restore launch.
///
/// The value validates restore ownership once, then provides the provider-specific
/// wrapper route and a shell-portable authorization transport for app-generated
/// startup input. Invalid providers and provider-invalid session identifiers cannot
/// create a restore launch.
///
/// ```swift
/// let launch = AgentRestoreLaunch(kind: "codex", sessionID: restoredSessionID)
/// let startupInput = launch?.authorizing(leadingShell: "", routedCommand: resumeCommand)
/// ```
public struct AgentRestoreLaunch: Sendable {
    /// The readable restore executable typed into cmux-owned terminals.
    ///
    /// ``TerminalSurface`` prepends the owning app's bundled `Resources/bin`
    /// directory to the terminal environment before the login shell starts, so
    /// this resolves to the same build while keeping restored scrollback useful.
    public static let cliStartupExecutableToken = "cmux"

    private let wrapper: ManagedAgentWrapperDescriptor
    private let sessionID: String

    /// Creates an authorized restore launch for a supported provider and session.
    ///
    /// - Parameters:
    ///   - kind: The persisted agent kind.
    ///   - sessionID: The exact session identifier that the wrapper must resume.
    public init?(kind: String?, sessionID: String?) {
        guard let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let wrapper = ManagedAgentWrapperDescriptor.registered(kind: normalizedKind),
              let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              wrapper.accepts(sessionID: sessionID) else {
            return nil
        }
        self.wrapper = wrapper
        self.sessionID = sessionID
    }

    /// The basename expected for a captured executable owned by this provider.
    public var executableName: String {
        wrapper.executableName
    }

    /// The managed per-surface wrapper token used to restore hook injection.
    public var wrapperShellExecutableToken: String {
        wrapper.wrapperShellExecutableToken
    }

    /// The environment key containing this surface's managed wrapper shim.
    public var wrapperShimEnvironmentKey: String {
        wrapper.wrapperShimEnvironmentKey
    }

    /// The environment key through which the wrapper preserves a captured executable.
    public var customExecutablePathEnvironmentKey: String {
        wrapper.customExecutablePathEnvironmentKey
    }

    /// The provider- and session-bound authorization value passed to the wrapper.
    public var authorizationEnvironmentValue: String {
        "\(wrapper.kind):\(sessionID)"
    }

    /// Wraps a provider-specific wrapper command so every supported login shell can dispatch it.
    ///
    /// - Parameter posixCommand: The command containing ``wrapperShellExecutableToken``.
    /// - Returns: A `/bin/sh -c` command that can be typed into POSIX and non-POSIX shells.
    public func portableWrapperShellCommand(posixCommand: String) -> String {
        wrapper.portableShellCommand(posixCommand: posixCommand)
    }

    /// Adds the one-shot restore authorization before an already routed command.
    ///
    /// `/usr/bin/env` carries the assignment because startup input is parsed by the
    /// user's login shell, and csh/tcsh do not accept POSIX `NAME=value command`
    /// syntax. `leadingShell` keeps app-owned working-directory guards outside the
    /// portable wrapper command.
    ///
    /// - Parameters:
    ///   - leadingShell: Shell syntax that must remain before the command executable.
    ///   - routedCommand: The command beginning at its executable after wrapper routing.
    /// - Returns: Startup input carrying provider- and session-bound authorization.
    public func authorizing(leadingShell: String, routedCommand: String) -> String {
        let assignment = "CMUX_AGENT_RESTORE_LAUNCH=\(authorizationEnvironmentValue)"
        return leadingShell + "/usr/bin/env '\(assignment)' " + routedCommand
    }

}
