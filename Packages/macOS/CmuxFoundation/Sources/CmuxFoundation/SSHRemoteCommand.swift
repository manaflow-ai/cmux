import Foundation

/// Separates OpenSSH terminal-allocation flags from the positional remote command.
///
/// OpenSSH accepts `-t` and `-T` after the destination until either a remote
/// executable or `--` begins the literal remote command. This value preserves
/// the exact recognized flag sequence for the live SSH invocation while
/// exposing only the remaining command arguments to command wrappers. It also
/// accepts a same-token cluster of TTY flags with OpenSSH's no-argument short
/// options, such as `-tq`.
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
    /// Only a leading run of TTY-bearing short-option tokens in
    /// `undelimitedArguments` is interpreted as OpenSSH configuration. Tokens
    /// in `delimitedArguments` are always literal remote-command arguments,
    /// including `-t`, `-T`, and `-tq`.
    ///
    /// - Parameters:
    ///   - undelimitedArguments: Arguments after the destination and before `--`.
    ///   - delimitedArguments: Literal remote-command arguments after `--`, or
    ///     `nil` when the caller did not provide a separator.
    public init(
        undelimitedArguments: [String],
        delimitedArguments: [String]? = nil
    ) {
        let ttyRequestCount = undelimitedArguments.prefix(while: Self.isTTYRequestArgument).count
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

    private static let noArgumentShortOptions = Set("46AaCfGgKkMNnqsTtVvXxYy")

    /// Returns whether a token is a TTY-bearing short-option cluster we can pass through safely.
    private static func isTTYRequestArgument(_ argument: String) -> Bool {
        guard argument.count > 1, argument.first == "-" else { return false }
        let flags = argument.dropFirst()
        guard flags.contains(where: { $0 == "t" || $0 == "T" }) else { return false }
        return flags.allSatisfy { noArgumentShortOptions.contains($0) }
    }

}
