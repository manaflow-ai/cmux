internal import Foundation

/// Resolves a remote executable across login and package-manager paths.
///
/// Noninteractive SSH commands often receive a smaller PATH than an
/// interactive shell. This builder gives remote features one deterministic
/// lookup contract without starting a user shell or mutating its startup files.
public struct RemoteExecutableCommandBuilder: Sendable {
    private let executableName: String
    private let notFoundSentinel: String

    /// Creates a resolver for one executable name.
    ///
    /// - Parameters:
    ///   - executableName: Basename to resolve, such as tmux or mosh-server.
    ///   - notFoundSentinel: Stable stderr text emitted with exit status 127.
    public init(executableName: String, notFoundSentinel: String) {
        self.executableName = executableName
        self.notFoundSentinel = notFoundSentinel
    }

    /// Returns argv that resolves the executable and runs it with the supplied arguments.
    ///
    /// - Parameter arguments: Arguments forwarded to the resolved executable.
    /// - Returns: An argv beginning with /bin/sh.
    public func remoteCommandArguments(arguments: [String]) -> [String] {
        [
            "/bin/sh",
            "-c",
            Self.executionShellScript,
            "cmux-remote-executable",
            executableName,
            notFoundSentinel,
        ] + arguments
    }

    /// Returns a shell-quoted remote command that resolves and executes argv.
    ///
    /// - Parameter arguments: Arguments forwarded to the resolved executable.
    /// - Returns: A command suitable for an OpenSSH remote-command string.
    public func remoteShellCommand(arguments: [String]) -> String {
        remoteCommandArguments(arguments: arguments)
            .map(\.remoteCommandShellQuoted)
            .joined(separator: " ")
    }

    /// A shell command that prints the resolved executable path.
    ///
    /// The command exits 127 and emits the configured sentinel when no
    /// executable can be found.
    public var resolutionProbeShellCommand: String {
        [
            "/bin/sh",
            "-c",
            Self.resolutionShellScript,
            "cmux-remote-executable",
            executableName,
            notFoundSentinel,
        ]
        .map(\.remoteCommandShellQuoted)
        .joined(separator: " ")
    }

    /// A command prefix to which a remote launcher may append arguments.
    ///
    /// Mosh appends its server arguments to the server value. With this prefix
    /// those arguments become the resolver's argv and reach the discovered
    /// server executable unchanged.
    public var remoteExecPrefixShellCommand: String {
        [
            "/bin/sh",
            "-c",
            Self.executionShellScript,
            "cmux-remote-executable",
            executableName,
            notFoundSentinel,
        ]
        .map(\.remoteCommandShellQuoted)
        .joined(separator: " ")
    }

    private static let resolutionShellScript =
        resolverPrefix +
        "if [ -n \"$cmux_executable_path\" ]; then printf '%s\\n' \"$cmux_executable_path\"; exit 0; fi; " +
        "printf '%s\\n' \"$cmux_not_found_sentinel\" >&2; exit 127"

    private static let executionShellScript =
        resolverPrefix +
        "if [ -n \"$cmux_executable_path\" ]; then exec \"$cmux_executable_path\" \"$@\"; fi; " +
        "printf '%s\\n' \"$cmux_not_found_sentinel\" >&2; exit 127"

    // Keep the resolver on one physical shell line so it is safe inside a
    // host-configured remote login shell before /bin/sh -c receives it.
    private static let resolverPrefix =
        "cmux_executable_name=$1; cmux_not_found_sentinel=$2; shift 2; cmux_executable_path=\"\"; " +
        "if command -v \"$cmux_executable_name\" >/dev/null 2>&1; then " +
        "cmux_executable_path=\"$(command -v \"$cmux_executable_name\")\"; fi; " +
        "if [ -z \"$cmux_executable_path\" ]; then " +
        "for cmux_dir in \"$HOME/.local/bin\" \"$HOME/bin\" /opt/homebrew/bin /usr/local/bin /opt/local/bin /usr/pkg/bin /snap/bin /usr/bin /bin; do " +
        "if [ -x \"$cmux_dir/$cmux_executable_name\" ]; then cmux_executable_path=\"$cmux_dir/$cmux_executable_name\"; break; fi; done; fi; " +
        "if [ -z \"$cmux_executable_path\" ] && [ -x /usr/libexec/path_helper ]; then " +
        "eval \"$(/usr/libexec/path_helper -s 2>/dev/null)\"; " +
        "if command -v \"$cmux_executable_name\" >/dev/null 2>&1; then " +
        "cmux_executable_path=\"$(command -v \"$cmux_executable_name\")\"; fi; fi; "
}

extension String {
    /// This string encoded as one POSIX shell argument.
    var remoteCommandShellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
