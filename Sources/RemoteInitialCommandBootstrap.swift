import Foundation

/// Stages a remote workspace command for one execution by the first interactive shell.
struct RemoteInitialCommandBootstrap {
    private let encodedCommand: String?

    init(command: String?) {
        guard let command,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            encodedCommand = nil
            return
        }
        encodedCommand = Data(command.utf8).base64EncodedString()
    }

    /// Stages the command without evaluating any of its contents in the local shell.
    var preparationLines: [String] {
        guard let encodedCommand else { return [] }
        return [
            "if [ ! -d \"$cmux_shell_dir/.initial-command.started\" ]; then",
            "  cmux_initial_command_b64='\(encodedCommand)'",
            "  cmux_initial_command_tmp=\"$cmux_shell_dir/.initial-command.$$\"",
            "  (umask 077; (printf %s \"$cmux_initial_command_b64\" | base64 -d 2>/dev/null || printf %s \"$cmux_initial_command_b64\" | base64 -D 2>/dev/null) > \"$cmux_initial_command_tmp\") || { rm -f -- \"$cmux_initial_command_tmp\"; exit 1; }",
            "  cmux_initial_command_file=\"$cmux_shell_dir/initial-command\"",
            "  mv -f -- \"$cmux_initial_command_tmp\" \"$cmux_initial_command_file\" || exit 1",
            "  chmod 600 \"$cmux_initial_command_file\" >/dev/null 2>&1 || true",
            "fi",
            "unset cmux_initial_command_b64 cmux_initial_command_tmp cmux_initial_command_file",
        ]
    }

    /// Atomically claims and sources the command after zsh or bash startup files load.
    var posixInteractiveShellLines: [String] {
        guard encodedCommand != nil else { return [] }
        return [
            "cmux_initial_command_file=\"$CMUX_SHELL_INTEGRATION_DIR/initial-command\"",
            "if [ -r \"$cmux_initial_command_file\" ] && mkdir \"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started\" 2>/dev/null; then",
            "  . \"$cmux_initial_command_file\"",
            "  rm -f -- \"$cmux_initial_command_file\" 2>/dev/null || true",
            "fi",
            "unset cmux_initial_command_file",
        ]
    }

    /// Atomically claims and sources the command from fish's initialization hook.
    var fishInteractiveShellCommand: String? {
        guard encodedCommand != nil else { return nil }
        return [
            "set -l cmux_initial_command_file \"$CMUX_SHELL_INTEGRATION_DIR/initial-command\"",
            "if test -r \"$cmux_initial_command_file\"; and command mkdir \"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started\" 2>/dev/null",
            "source \"$cmux_initial_command_file\"",
            "command rm -f -- \"$cmux_initial_command_file\" >/dev/null 2>&1; or true",
            "end",
        ].joined(separator: "; ")
    }

    /// Atomically claims and runs the command as a script in an otherwise unsupported shell.
    var fallbackShellLines: [String] {
        guard encodedCommand != nil else { return [] }
        return [
            "cmux_initial_command_file=\"$CMUX_SHELL_INTEGRATION_DIR/initial-command\"",
            "if [ -r \"$cmux_initial_command_file\" ] && mkdir \"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started\" 2>/dev/null; then",
            "  \"$CMUX_LOGIN_SHELL\" \"$cmux_initial_command_file\"",
            "  rm -f -- \"$cmux_initial_command_file\" 2>/dev/null || true",
            "fi",
            "unset cmux_initial_command_file",
        ]
    }
}
