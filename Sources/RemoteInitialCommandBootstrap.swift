import Foundation

/// Stages a remote workspace command for one execution by the first interactive shell.
struct RemoteInitialCommandBootstrap {
    private let encodedCommand: String?
    private let encodedUnsupportedShellMessage: String
    /// Embedded in the persisted bootstrap so reattaches reuse it while later workspaces do not.
    private let stateKey = UUID().uuidString.lowercased()

    init(command: String?) {
        let unsupportedShellMessage = String(
            localized: "cli.ssh.initialCommand.unsupportedShell",
            defaultValue: "[cmux] Initial command was not run because cmux does not support initial commands for this remote login shell. Reconnect with a supported shell to retry it."
        )
        encodedUnsupportedShellMessage = Data(unsupportedShellMessage.utf8).base64EncodedString()
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
            "cmux_initial_command_b64='\(encodedCommand)'",
            "export CMUX_INITIAL_COMMAND_B64=\"$cmux_initial_command_b64\"",
            "unset cmux_initial_command_b64",
        ]
    }

    /// Decodes, atomically claims, and runs the command after zsh or bash startup files load.
    var posixInteractiveShellLines: [String] {
        guard encodedCommand != nil else { return [] }
        return [
            "cmux_initial_command_started=\"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "unset cmux_initial_command cmux_initial_command_decode_status",
            "if [ -n \"${CMUX_INITIAL_COMMAND_B64:-}\" ]; then",
            "  cmux_initial_command=$(printf %s \"$CMUX_INITIAL_COMMAND_B64\" | base64 -d 2>/dev/null || printf %s \"$CMUX_INITIAL_COMMAND_B64\" | base64 -D 2>/dev/null)",
            "  cmux_initial_command_decode_status=$?",
            "  unset CMUX_INITIAL_COMMAND_B64",
            "  if [ \"$cmux_initial_command_decode_status\" -eq 0 ] && mkdir \"$cmux_initial_command_started\" 2>/dev/null; then eval \"$cmux_initial_command\"; fi",
            "else",
            "  unset CMUX_INITIAL_COMMAND_B64",
            "fi",
            "unset cmux_initial_command cmux_initial_command_decode_status cmux_initial_command_started",
        ]
    }

    /// Decodes, atomically claims, and runs the command from fish's initialization hook.
    var fishInteractiveShellCommand: String? {
        guard encodedCommand != nil else { return nil }
        return [
            "set -l cmux_initial_command_started \"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "if test -n \"$CMUX_INITIAL_COMMAND_B64\"",
            "set -l cmux_initial_command (begin; printf %s \"$CMUX_INITIAL_COMMAND_B64\" | base64 -d 2>/dev/null; or printf %s \"$CMUX_INITIAL_COMMAND_B64\" | base64 -D 2>/dev/null; end | string collect)",
            "set -l cmux_initial_command_decode_status $status",
            "set -e CMUX_INITIAL_COMMAND_B64",
            "if test \"$cmux_initial_command_decode_status\" -eq 0; and command mkdir \"$cmux_initial_command_started\" 2>/dev/null; eval \"$cmux_initial_command\"; end",
            "else",
            "set -e CMUX_INITIAL_COMMAND_B64",
            "end",
        ].joined(separator: "; ")
    }

    /// Runs the command through verified execute-then-interactive shell adapters.
    var fallbackShellLines: [String] {
        guard encodedCommand != nil else { return [] }
        return [
            "cmux_initial_command_started=\"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "unset cmux_initial_command cmux_initial_command_decode_status",
            "if [ -n \"${CMUX_INITIAL_COMMAND_B64:-}\" ]; then",
            "  cmux_initial_command=$(printf %s \"$CMUX_INITIAL_COMMAND_B64\" | base64 -d 2>/dev/null || printf %s \"$CMUX_INITIAL_COMMAND_B64\" | base64 -D 2>/dev/null)",
            "  cmux_initial_command_decode_status=$?",
            "  unset CMUX_INITIAL_COMMAND_B64",
            "  if [ \"$cmux_initial_command_decode_status\" -eq 0 ]; then",
            "    case \"${CMUX_LOGIN_SHELL##*/}\" in",
            "      csh|tcsh) if mkdir \"$cmux_initial_command_started\" 2>/dev/null; then exec \"$CMUX_LOGIN_SHELL\" -i -c 'eval \"$argv[2]\"; exec \"$argv[1]\" -i' \"$CMUX_LOGIN_SHELL\" \"$cmux_initial_command\"; fi ;;",
            "      sh|dash|ksh|mksh|ash|yash|posh) if mkdir \"$cmux_initial_command_started\" 2>/dev/null; then exec \"$CMUX_LOGIN_SHELL\" -i -c 'eval \"$1\"; exec \"$0\" -i' \"$CMUX_LOGIN_SHELL\" \"$cmux_initial_command\"; fi ;;",
            // Nushell src/command.rs: --execute runs then stays interactive; --commands exits.
            "      nu|nushell) if mkdir \"$cmux_initial_command_started\" 2>/dev/null; then exec \"$CMUX_LOGIN_SHELL\" --execute \"$cmux_initial_command\"; fi ;;",
            "      pwsh|powershell) if mkdir \"$cmux_initial_command_started\" 2>/dev/null; then exec \"$CMUX_LOGIN_SHELL\" -NoExit -Command \"$cmux_initial_command\"; fi ;;",
            "      *) printf %s '\(encodedUnsupportedShellMessage)' | base64 -d 1>&2 2>/dev/null || printf %s '\(encodedUnsupportedShellMessage)' | base64 -D 1>&2 2>/dev/null; printf '\\n' >&2 ;;",
            "    esac",
            "  fi",
            "else",
            "  unset CMUX_INITIAL_COMMAND_B64",
            "fi",
            "unset cmux_initial_command cmux_initial_command_decode_status cmux_initial_command_started",
        ]
    }
}
