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

    /// Returns whether a token mixes a TTY flag with another short SSH option.
    ///
    /// cmux forwards only the supported TTY subset after a destination. Callers
    /// should pass other SSH options with ``--ssh-option`` and use `--` when a
    /// literal remote command begins with a dash; silently moving a mixed token
    /// to the remote shell would change OpenSSH's meaning.
    ///
    /// - Parameter argument: A token that appeared after an SSH destination.
    /// - Returns: `true` for short-option clusters such as `-tq` or `-4t`.
    public static func isMixedTTYOptionCluster(_ argument: String) -> Bool {
        guard argument.count > 2,
              argument.first == "-",
              argument.dropFirst().first != "-" else {
            return false
        }
        let flags = argument.dropFirst()
        return flags.contains(where: { $0 == "t" || $0 == "T" })
            && flags.contains(where: { $0 != "t" && $0 != "T" })
    }

    /// Returns SSH options that durably encode this command's effective TTY request.
    ///
    /// The live invocation retains ``ttyRequestArguments`` because OpenSSH's
    /// state transitions depend on their exact order. Session restoration has
    /// only SSH options, so this method evaluates those transitions against the
    /// first existing `RequestTTY` option and replaces that option with the
    /// equivalent final `no`, `yes`, or `force` value.
    ///
    /// - Parameter options: OpenSSH `-o` values in live invocation order.
    /// - Returns: `options` unchanged when no TTY flags were recognized;
    ///   otherwise, the same non-`RequestTTY` options plus one effective value.
    public func sshOptionsPersistingTTYRequest(in options: [String]) -> [String] {
        guard !ttyRequestArguments.isEmpty else { return options }

        let resolver = SSHAgentSocketResolver()
        let request = effectiveTTYRequest(in: options, resolver: resolver)

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
            resolver: SSHAgentSocketResolver()
        ) == .disabled
    }

    private func effectiveTTYRequest(
        in options: [String],
        resolver: SSHAgentSocketResolver
    ) -> SSHRemoteCommandTTYRequest {
        var request = SSHRemoteCommandTTYRequest(
            optionValue: resolver.optionValue(named: "RequestTTY", in: options)
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
