import Foundation

/// Separates OpenSSH terminal-allocation flags from the positional remote command.
///
/// OpenSSH accepts `-t` and `-T` after the destination until either a remote
/// executable or `--` begins the literal remote command. This value preserves
/// the exact recognized flag sequence for the live SSH invocation while
/// exposing only the remaining command arguments to command wrappers.
///
/// ```swift
/// let command = SSHRemoteCommand(
///     undelimitedArguments: ["-t", "docker", "exec"]
/// )
/// // command.ttyRequestArguments == ["-t"]
/// // command.arguments == ["docker", "exec"]
/// ```
public struct SSHRemoteCommand: Equatable, Sendable {
    /// Positional arguments that OpenSSH sends to the remote login shell.
    public let arguments: [String]

    /// The exact leading `-t`/`-T` argument sequence applied to OpenSSH.
    public let ttyRequestArguments: [String]

    /// Whether `--` explicitly separated OpenSSH options from the remote command.
    public let usesArgumentSeparator: Bool

    /// Creates a remote command from arguments on both sides of an optional `--` separator.
    ///
    /// Only a leading run of `-t`/`-T` tokens in `undelimitedArguments` is
    /// interpreted as OpenSSH configuration. Tokens in `delimitedArguments`
    /// are always literal remote-command arguments, including `-t` and `-T`.
    ///
    /// - Parameters:
    ///   - undelimitedArguments: Arguments after the destination and before `--`.
    ///   - delimitedArguments: Literal remote-command arguments after `--`, or
    ///     `nil` when the caller did not provide a separator.
    public init(
        undelimitedArguments: [String],
        delimitedArguments: [String]? = nil
    ) {
        let ttyRequestCount = undelimitedArguments.prefix(while: { argument in
            argument.count > 1
                && argument.first == "-"
                && argument.dropFirst().allSatisfy { $0 == "t" || $0 == "T" }
        }).count
        ttyRequestArguments = Array(undelimitedArguments.prefix(ttyRequestCount))
        arguments = Array(undelimitedArguments.dropFirst(ttyRequestCount))
            + (delimitedArguments ?? [])
        usesArgumentSeparator = delimitedArguments != nil
    }

    /// Returns SSH options that durably encode this command's effective TTY request.
    ///
    /// The live invocation retains ``ttyRequestArguments`` because OpenSSH's
    /// state transitions depend on their exact order. Session restoration has
    /// only SSH options, so this method evaluates those transitions against the
    /// first existing `RequestTTY` option and replaces that option with the
    /// equivalent final `no`, `yes`, or `force` value.
    ///
    /// - Parameters:
    ///   - options: OpenSSH `-o` values in live invocation order.
    ///   - hostRequestTTY: The effective `requesttty` value from `ssh -G`,
    ///     used only when `options` has no explicit `RequestTTY` value.
    /// - Returns: `options` unchanged when no TTY flags were recognized;
    ///   otherwise, the same non-`RequestTTY` options plus one effective value.
    public func sshOptionsPersistingTTYRequest(
        in options: [String],
        hostRequestTTY: String? = nil
    ) -> [String] {
        guard !ttyRequestArguments.isEmpty else { return options }

        let resolver = SSHAgentSocketResolver()
        let request = effectiveTTYRequest(
            in: options,
            hostRequestTTY: hostRequestTTY,
            resolver: resolver
        )

        return resolver.removingOptions(named: "RequestTTY", from: options)
            + ["RequestTTY=\(request.optionValue)"]
    }

    /// Returns whether the effective OpenSSH configuration explicitly disables a TTY.
    ///
    /// - Parameter options: OpenSSH `-o` values applied before
    ///   ``ttyRequestArguments``.
    /// - Returns: `true` when the final `RequestTTY` state is `no`.
    public func disablesTTY(in options: [String]) -> Bool {
        effectiveTTYRequest(
            in: options,
            hostRequestTTY: nil,
            resolver: SSHAgentSocketResolver()
        ) == .disabled
    }

    private func effectiveTTYRequest(
        in options: [String],
        hostRequestTTY: String?,
        resolver: SSHAgentSocketResolver
    ) -> SSHRemoteCommandTTYRequest {
        var request = SSHRemoteCommandTTYRequest(
            optionValue: resolver.optionValue(named: "RequestTTY", in: options)
                ?? hostRequestTTY
        )
        for argument in ttyRequestArguments {
            for flag in argument.dropFirst() where flag == "t" || flag == "T" {
                if flag == "T" {
                    request = .disabled
                } else {
                    request = request == .enabled ? .forced : .enabled
                }
            }
        }
        return request
    }

}
