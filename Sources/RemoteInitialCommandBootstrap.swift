import Foundation

/// Stages a remote workspace command for one execution by the first interactive shell.
struct RemoteInitialCommandBootstrap {
    private let encodedCommand: String?
    /// Embedded in the persisted bootstrap so reattaches reuse it while later workspaces do not.
    private let stateKey = UUID().uuidString.lowercased()

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
            "unset CMUX_INITIAL_COMMAND_FILE",
            "if [ ! -d \"$cmux_shell_dir/.initial-command.started.\(stateKey)\" ]; then",
            "  cmux_initial_command_b64='\(encodedCommand)'",
            "  cmux_initial_command_file=\"$cmux_shell_dir/initial-command.\(stateKey).$$\"",
            "  (umask 077; (printf %s \"$cmux_initial_command_b64\" | base64 -d 2>/dev/null || printf %s \"$cmux_initial_command_b64\" | base64 -D 2>/dev/null) > \"$cmux_initial_command_file\") || { rm -f -- \"$cmux_initial_command_file\"; exit 1; }",
            "  chmod 600 \"$cmux_initial_command_file\" >/dev/null 2>&1 || true",
            "  export CMUX_INITIAL_COMMAND_FILE=\"$cmux_initial_command_file\"",
            "fi",
            "unset cmux_initial_command_b64 cmux_initial_command_file",
        ]
    }

    /// Atomically claims and sources the command after zsh or bash startup files load.
    var posixInteractiveShellLines: [String] {
        guard encodedCommand != nil else { return [] }
        return [
            "cmux_initial_command_file=\"${CMUX_INITIAL_COMMAND_FILE:-}\"",
            "cmux_initial_command_started=\"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "unset CMUX_INITIAL_COMMAND_FILE",
            "if [ -r \"$cmux_initial_command_file\" ]; then",
            "  if mkdir \"$cmux_initial_command_started\" 2>/dev/null; then . \"$cmux_initial_command_file\"; fi",
            "  rm -f -- \"$cmux_initial_command_file\" 2>/dev/null || true",
            "fi",
            "unset cmux_initial_command_file cmux_initial_command_started",
        ]
    }

    /// Atomically claims and sources the command from fish's initialization hook.
    var fishInteractiveShellCommand: String? {
        guard encodedCommand != nil else { return nil }
        return [
            "set -l cmux_initial_command_file \"$CMUX_INITIAL_COMMAND_FILE\"",
            "set -l cmux_initial_command_started \"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "set -e CMUX_INITIAL_COMMAND_FILE",
            "if test -r \"$cmux_initial_command_file\"",
            "if command mkdir \"$cmux_initial_command_started\" 2>/dev/null; source \"$cmux_initial_command_file\"; end",
            "command rm -f -- \"$cmux_initial_command_file\" >/dev/null 2>&1; or true",
            "end",
        ].joined(separator: "; ")
    }

    /// Atomically claims the command and carries its state into an otherwise unsupported shell.
    var fallbackShellLines: [String] {
        guard encodedCommand != nil else { return [] }
        return [
            "cmux_initial_command_file=\"${CMUX_INITIAL_COMMAND_FILE:-}\"",
            "cmux_initial_command_started=\"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "unset CMUX_INITIAL_COMMAND_FILE",
            "if [ -r \"$cmux_initial_command_file\" ]; then",
            "  if mkdir \"$cmux_initial_command_started\" 2>/dev/null; then",
            "    case \"${CMUX_LOGIN_SHELL##*/}\" in",
            "      csh|tcsh) exec \"$CMUX_LOGIN_SHELL\" -i -c 'source \"$argv[2]\"; /bin/rm -f -- \"$argv[2]\"; exec \"$argv[1]\" -i' \"$CMUX_LOGIN_SHELL\" \"$cmux_initial_command_file\" ;;",
            "      *) exec \"$CMUX_LOGIN_SHELL\" -i -c '. \"$1\"; /bin/rm -f -- \"$1\"; exec \"$0\" -i' \"$CMUX_LOGIN_SHELL\" \"$cmux_initial_command_file\" ;;",
            "    esac",
            "  fi",
            "  rm -f -- \"$cmux_initial_command_file\" 2>/dev/null || true",
            "fi",
            "unset cmux_initial_command_file cmux_initial_command_started",
        ]
    }
}
