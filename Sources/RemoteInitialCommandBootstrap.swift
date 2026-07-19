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
            "cmux_initial_command_b64='\(encodedCommand)'",
            "export CMUX_INITIAL_COMMAND_B64=\"$cmux_initial_command_b64\"",
            "unset cmux_initial_command_b64",
        ]
    }

    /// Atomically claims and runs the command after zsh or bash startup files load.
    var posixInteractiveShellLines: [String] {
        guard encodedCommand != nil else { return [] }
        return [
            "cmux_initial_command_started=\"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "unset cmux_initial_command cmux_initial_command_decode_status",
            "if [ -n \"${CMUX_INITIAL_COMMAND_B64:-}\" ] && mkdir \"$cmux_initial_command_started\" 2>/dev/null; then",
            "  cmux_initial_command=$(printf %s \"$CMUX_INITIAL_COMMAND_B64\" | base64 -d 2>/dev/null || printf %s \"$CMUX_INITIAL_COMMAND_B64\" | base64 -D 2>/dev/null)",
            "  cmux_initial_command_decode_status=$?",
            "  unset CMUX_INITIAL_COMMAND_B64",
            "  if [ \"$cmux_initial_command_decode_status\" -eq 0 ]; then eval \"$cmux_initial_command\"; fi",
            "else",
            "  unset CMUX_INITIAL_COMMAND_B64",
            "fi",
            "unset cmux_initial_command cmux_initial_command_decode_status cmux_initial_command_started",
        ]
    }

    /// Atomically claims and runs the command from fish's initialization hook.
    var fishInteractiveShellCommand: String? {
        guard encodedCommand != nil else { return nil }
        return [
            "set -l cmux_initial_command_started \"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "if test -n \"$CMUX_INITIAL_COMMAND_B64\"; and command mkdir \"$cmux_initial_command_started\" 2>/dev/null",
            "set -l cmux_initial_command (begin; printf %s \"$CMUX_INITIAL_COMMAND_B64\" | base64 -d 2>/dev/null; or printf %s \"$CMUX_INITIAL_COMMAND_B64\" | base64 -D 2>/dev/null; end | string collect)",
            "set -l cmux_initial_command_decode_status $pipestatus[1]",
            "set -e CMUX_INITIAL_COMMAND_B64",
            "if test \"$cmux_initial_command_decode_status\" -eq 0; eval \"$cmux_initial_command\"; end",
            "else",
            "set -e CMUX_INITIAL_COMMAND_B64",
            "end",
        ].joined(separator: "; ")
    }

    /// Atomically claims the command and runs it through the login shell's interactive mode.
    var fallbackShellLines: [String] {
        guard encodedCommand != nil else { return [] }
        return [
            "cmux_initial_command_started=\"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "unset cmux_initial_command cmux_initial_command_decode_status",
            "if [ -n \"${CMUX_INITIAL_COMMAND_B64:-}\" ] && mkdir \"$cmux_initial_command_started\" 2>/dev/null; then",
            "  cmux_initial_command=$(printf %s \"$CMUX_INITIAL_COMMAND_B64\" | base64 -d 2>/dev/null || printf %s \"$CMUX_INITIAL_COMMAND_B64\" | base64 -D 2>/dev/null)",
            "  cmux_initial_command_decode_status=$?",
            "  unset CMUX_INITIAL_COMMAND_B64",
            "  if [ \"$cmux_initial_command_decode_status\" -eq 0 ]; then",
            "    case \"${CMUX_LOGIN_SHELL##*/}\" in",
            "      csh|tcsh) exec \"$CMUX_LOGIN_SHELL\" -i -c 'eval \"$argv[2]\"; exec \"$argv[1]\" -i' \"$CMUX_LOGIN_SHELL\" \"$cmux_initial_command\" ;;",
            "      sh|dash|ksh|mksh|ash|yash|posh) exec \"$CMUX_LOGIN_SHELL\" -i -c 'eval \"$1\"; exec \"$0\" -i' \"$CMUX_LOGIN_SHELL\" \"$cmux_initial_command\" ;;",
            "      nu|nushell) exec \"$CMUX_LOGIN_SHELL\" -e \"$cmux_initial_command\" ;;",
            "      pwsh|powershell) exec \"$CMUX_LOGIN_SHELL\" -NoExit -Command \"$cmux_initial_command\" ;;",
            "      *) exec \"$CMUX_LOGIN_SHELL\" -i -c \"$cmux_initial_command\" ;;",
            "    esac",
            "  fi",
            "else",
            "  unset CMUX_INITIAL_COMMAND_B64",
            "fi",
            "unset cmux_initial_command cmux_initial_command_decode_status cmux_initial_command_started",
        ]
    }
}
