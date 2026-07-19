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
            "unset CMUX_INITIAL_COMMAND_FILE",
            "cmux_initial_command_started=\"$cmux_shell_dir/.initial-command.started.\(stateKey)\"",
            "if [ ! -d \"$cmux_initial_command_started\" ]; then",
            "  cmux_initial_command_file=\"$cmux_shell_dir/.initial-command.payload.\(stateKey).$$\"",
            "  cmux_initial_command_tmp=\"$cmux_initial_command_file.tmp\"",
            "  if (umask 077; printf %s '\(encodedCommand)' > \"$cmux_initial_command_tmp\") && mv -f -- \"$cmux_initial_command_tmp\" \"$cmux_initial_command_file\"; then",
            "    chmod 600 \"$cmux_initial_command_file\" >/dev/null 2>&1 || true",
            "    export CMUX_INITIAL_COMMAND_FILE=\"$cmux_initial_command_file\"",
            "  else",
            "    rm -f -- \"$cmux_initial_command_tmp\" \"$cmux_initial_command_file\" 2>/dev/null || true",
            "  fi",
            "  unset cmux_initial_command_file cmux_initial_command_tmp",
            "fi",
            "unset cmux_initial_command_started",
        ]
    }

    /// Decodes, atomically claims, and runs the command after zsh or bash startup files load.
    var posixInteractiveShellLines: [String] {
        guard encodedCommand != nil else { return [] }
        return [
            "cmux_initial_command_file=\"${CMUX_INITIAL_COMMAND_FILE:-}\"",
            "cmux_initial_command_started=\"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "unset cmux_initial_command_b64 cmux_initial_command cmux_initial_command_decode_status cmux_initial_command_file_status",
            "if [ -r \"$cmux_initial_command_file\" ]; then",
            "  cmux_initial_command_b64=$(cat -- \"$cmux_initial_command_file\" 2>/dev/null)",
            "  cmux_initial_command_file_status=$?",
            "else",
            "  cmux_initial_command_file_status=1",
            "fi",
            "unset CMUX_INITIAL_COMMAND_FILE",
            "if [ -n \"$cmux_initial_command_file\" ]; then rm -f -- \"$cmux_initial_command_file\" 2>/dev/null || true; fi",
            "if [ \"$cmux_initial_command_file_status\" -eq 0 ] && [ -n \"$cmux_initial_command_b64\" ]; then",
            "  cmux_initial_command=$(printf %s \"$cmux_initial_command_b64\" | base64 -d 2>/dev/null || printf %s \"$cmux_initial_command_b64\" | base64 -D 2>/dev/null)",
            "  cmux_initial_command_decode_status=$?",
            "  if [ \"$cmux_initial_command_decode_status\" -eq 0 ] && mkdir \"$cmux_initial_command_started\" 2>/dev/null; then eval \"$cmux_initial_command\"; fi",
            "fi",
            "unset cmux_initial_command_b64 cmux_initial_command cmux_initial_command_decode_status cmux_initial_command_file_status cmux_initial_command_file cmux_initial_command_started",
        ]
    }

    /// Decodes, atomically claims, and runs the command from fish's initialization hook.
    var fishInteractiveShellCommand: String? {
        guard encodedCommand != nil else { return nil }
        return [
            "set -l cmux_initial_command_file \"$CMUX_INITIAL_COMMAND_FILE\"",
            "set -l cmux_initial_command_started \"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "set -l cmux_initial_command_b64",
            "set -l cmux_initial_command_file_status 1",
            "if test -r \"$cmux_initial_command_file\"",
            "set cmux_initial_command_b64 (command cat -- \"$cmux_initial_command_file\" 2>/dev/null)",
            "set cmux_initial_command_file_status $status",
            "end",
            "set -e CMUX_INITIAL_COMMAND_FILE",
            "if test -n \"$cmux_initial_command_file\"; command rm -f -- \"$cmux_initial_command_file\" >/dev/null 2>&1; or true; end",
            "if test \"$cmux_initial_command_file_status\" -eq 0; and test -n \"$cmux_initial_command_b64\"",
            "set -l cmux_initial_command_decode_flag",
            "if printf %s \"$cmux_initial_command_b64\" | base64 -d >/dev/null 2>&1",
            "set cmux_initial_command_decode_flag -d",
            "else if printf %s \"$cmux_initial_command_b64\" | base64 -D >/dev/null 2>&1",
            "set cmux_initial_command_decode_flag -D",
            "end",
            "if test -n \"$cmux_initial_command_decode_flag\"",
            "set -l cmux_initial_command (printf %s \"$cmux_initial_command_b64\" | base64 \"$cmux_initial_command_decode_flag\" 2>/dev/null | string collect)",
            "if command mkdir \"$cmux_initial_command_started\" 2>/dev/null; eval \"$cmux_initial_command\"; end",
            "end",
            "end",
        ].joined(separator: "; ")
    }

    /// Runs the command through verified execute-then-interactive shell adapters.
    var fallbackShellLines: [String] {
        guard encodedCommand != nil else { return [] }
        return [
            "cmux_initial_command_file=\"${CMUX_INITIAL_COMMAND_FILE:-}\"",
            "cmux_initial_command_started=\"$CMUX_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "unset cmux_initial_command_b64 cmux_initial_command cmux_initial_command_decode_status cmux_initial_command_file_status",
            "case \"${CMUX_LOGIN_SHELL##*/}\" in",
            "  csh|tcsh|sh|dash|ksh|mksh|ash|yash|posh|nu|nushell|pwsh|powershell)",
            "    if [ -r \"$cmux_initial_command_file\" ]; then",
            "      cmux_initial_command_b64=$(cat -- \"$cmux_initial_command_file\" 2>/dev/null)",
            "      cmux_initial_command_file_status=$?",
            "    else",
            "      cmux_initial_command_file_status=1",
            "    fi",
            "    unset CMUX_INITIAL_COMMAND_FILE",
            "    if [ -n \"$cmux_initial_command_file\" ]; then rm -f -- \"$cmux_initial_command_file\" 2>/dev/null || true; fi",
            "    if [ \"$cmux_initial_command_file_status\" -eq 0 ] && [ -n \"$cmux_initial_command_b64\" ]; then",
            "      cmux_initial_command=$(printf %s \"$cmux_initial_command_b64\" | base64 -d 2>/dev/null || printf %s \"$cmux_initial_command_b64\" | base64 -D 2>/dev/null)",
            "      cmux_initial_command_decode_status=$?",
            "      if [ \"$cmux_initial_command_decode_status\" -eq 0 ]; then",
            "        case \"${CMUX_LOGIN_SHELL##*/}\" in",
            "          csh|tcsh) if mkdir \"$cmux_initial_command_started\" 2>/dev/null; then exec \"$CMUX_LOGIN_SHELL\" -i -c 'eval \"$argv[2]\"; exec \"$argv[1]\" -i' \"$CMUX_LOGIN_SHELL\" \"$cmux_initial_command\"; fi ;;",
            "          sh|dash|ksh|mksh|ash|yash|posh) if mkdir \"$cmux_initial_command_started\" 2>/dev/null; then exec \"$CMUX_LOGIN_SHELL\" -i -c 'eval \"$1\"; exec \"$0\" -i' \"$CMUX_LOGIN_SHELL\" \"$cmux_initial_command\"; fi ;;",
            // Nushell src/command.rs: --execute runs then stays interactive; --commands exits.
            "          nu|nushell) if mkdir \"$cmux_initial_command_started\" 2>/dev/null; then exec \"$CMUX_LOGIN_SHELL\" --execute \"$cmux_initial_command\"; fi ;;",
            "          pwsh|powershell) if mkdir \"$cmux_initial_command_started\" 2>/dev/null; then exec \"$CMUX_LOGIN_SHELL\" -NoExit -Command \"$cmux_initial_command\"; fi ;;",
            "        esac",
            "      fi",
            "    fi",
            "    ;;",
            "  *)",
            "    unset CMUX_INITIAL_COMMAND_FILE",
            "    if [ -n \"$cmux_initial_command_file\" ]; then rm -f -- \"$cmux_initial_command_file\" 2>/dev/null || true; fi",
            "    printf %s '\(encodedUnsupportedShellMessage)' | base64 -d 1>&2 2>/dev/null || printf %s '\(encodedUnsupportedShellMessage)' | base64 -D 1>&2 2>/dev/null; printf '\\n' >&2",
            "    ;;",
            "esac",
            "unset cmux_initial_command_b64 cmux_initial_command cmux_initial_command_decode_status cmux_initial_command_file_status cmux_initial_command_file cmux_initial_command_started",
        ]
    }
}
