/// Removes the macOS-only ctype shorthand before OpenSSH forwards the environment.
///
/// A bare `UTF-8` is valid on macOS but makes Linux login shells warn before
/// remote bootstrap code can run. Leave locale selection to the host's defaults,
/// inherited full locale names, and explicit SSH `SetEnv` configuration instead
/// of guessing which locales the host has installed.
public struct SSHLocaleEnvironment: Sendable {
    private let macOSCType = "UTF-8"

    /// Creates the locale policy shared by SSH process and shell launchers.
    public init() {}

    /// Removes only the inherited bare macOS ctype value.
    ///
    /// - Parameter environment: The environment about to be inherited by SSH.
    /// - Returns: An environment preserving all other variables and locale values.
    public func sanitized(_ environment: [String: String]) -> [String: String] {
        guard environment["LC_CTYPE"] == macOSCType else { return environment }
        var result = environment
        result.removeValue(forKey: "LC_CTYPE")
        return result
    }

    /// POSIX shell setup evaluated when a persisted SSH launcher actually runs.
    ///
    /// Unsetting the variable prevents `SendEnv LC_*` in system SSH configuration
    /// from forwarding it again. `LC_ALL` cannot suppress Bash's direct check of
    /// `LC_CTYPE`, so sanitize it independently of the other locale categories.
    public var shellSetup: String {
        "if [ \"${LC_CTYPE-}\" = \"\(macOSCType)\" ]; then unset LC_CTYPE; fi"
    }

    /// Wraps an SSH argument prefix without changing the parent shell's locale.
    ///
    /// Mosh needs the local UTF-8 locale, while its SSH bootstrap must not forward
    /// the macOS shorthand. Additional SSH arguments can follow this shell text.
    ///
    /// - Parameter arguments: SSH executable and arguments, before shell quoting.
    /// - Returns: A shell command prefix that sanitizes only the SSH child.
    public func shellCommandPrefix(arguments: [String]) -> String {
        let script = shellSetup + "; exec \"$@\""
        return (["/bin/sh", "-c", script, "cmux-ssh"] + arguments)
            .map(\.remoteCommandShellQuoted)
            .joined(separator: " ")
    }
}
