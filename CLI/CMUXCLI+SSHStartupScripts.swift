import Foundation

extension CMUXCLI {
    func buildSSHStartupCommand(
        sshCommand: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        isShellSnippet: Bool = false,
        passwordCredential: String? = nil,
        controlPathPreflightShellFunction: String? = nil,
        retryPTYAttachStatus: Bool = false,
        reconnectLimitDefault: Int = 20
    ) throws -> String {
        let script = buildSSHStartupScriptBody(
            sshCommand: sshCommand,
            shellFeatures: shellFeatures,
            remoteRelayPort: remoteRelayPort,
            isShellSnippet: isShellSnippet,
            passwordCredential: passwordCredential,
            controlPathPreflightShellFunction: controlPathPreflightShellFunction,
            oneTimeCommand: nil,
            retryPTYAttachStatus: retryPTYAttachStatus,
            reconnectLimitDefault: reconnectLimitDefault
        )
        return try writeSSHStartupScript(script, remoteRelayPort: remoteRelayPort)
    }

    func buildReusableSSHStartupCommand(
        sshCommand: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        isShellSnippet: Bool = false,
        passwordCredential: String? = nil,
        controlPathPreflightShellFunction: String? = nil,
        oneTimeCommand: String? = nil,
        retryPTYAttachStatus: Bool = false,
        reconnectLimitDefault: Int = 20
    ) -> String {
        // Reusable commands are persisted in workspace metadata and can be emitted over the socket API.
        // Short-lived credentials must stay in the one-shot launcher path only.
        let script = buildSSHStartupScriptBody(
            sshCommand: sshCommand,
            shellFeatures: shellFeatures,
            remoteRelayPort: remoteRelayPort,
            isShellSnippet: isShellSnippet,
            passwordCredential: nil,
            controlPathPreflightShellFunction: controlPathPreflightShellFunction,
            oneTimeCommand: oneTimeCommand,
            retryPTYAttachStatus: retryPTYAttachStatus,
            reconnectLimitDefault: reconnectLimitDefault
        )
        return reusableShellStartupCommand(
            scriptBody: script,
            tempPrefix: "cmux-ssh-startup"
        )
    }

    func buildReusableSSHPTYAttachStartupCommand(
        remoteShellCommand: String,
        remoteRelayPort: Int
    ) -> String {
        let attachScript = buildSSHPTYAttachScriptBody(
            remoteShellCommand: remoteShellCommand
        )
        return buildReusableSSHStartupCommand(
            sshCommand: attachScript,
            shellFeatures: "",
            remoteRelayPort: remoteRelayPort,
            isShellSnippet: true,
            retryPTYAttachStatus: true
        )
    }

    func buildSSHPTYAttachScriptBody(
        remoteShellCommand: String
    ) -> String {
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let commandB64 = Data(remoteShellCommand.utf8).base64EncodedString()
        let attachCommand = [
            shellQuote(executablePath),
            "ssh-pty-attach",
            "--wait",
            "--workspace", "\"$cmux_ssh_pty_workspace_id\"",
            "--session-id", "\"$cmux_ssh_pty_session_id\"",
            "--lifecycle-id", "\"$cmux_ssh_pty_lifecycle_id\"",
            "--attachment-id", "\"$cmux_ssh_pty_surface_id\"",
            "--command-b64", shellQuote(commandB64),
        ].joined(separator: " ")
        return [
            "cmux_ssh_pty_workspace_id=\"${CMUX_WORKSPACE_ID:-}\"",
            "cmux_ssh_pty_surface_id=\"${CMUX_SURFACE_ID:-}\"",
            "if [ -z \"$cmux_ssh_pty_workspace_id\" ]; then printf '%s\\n' '[cmux] required workspace context missing for SSH PTY attach.' >&2; exit 1; fi",
            "if [ -z \"$cmux_ssh_pty_surface_id\" ]; then printf '%s\\n' '[cmux] required terminal context missing for SSH PTY attach.' >&2; exit 1; fi",
            "cmux_ssh_pty_session_id=\"$CMUX_SSH_PTY_SESSION_ID\"",
            "cmux_ssh_pty_lifecycle_id=\"$CMUX_SSH_PTY_LIFECYCLE_ID\"",
            "exec \(attachCommand)",
        ].joined(separator: "\n")
    }

    func sshAskpassExecShellScript(passwordCredential: String) -> String {
        let passwordB64 = Data(passwordCredential.utf8).base64EncodedString()
        return [
            "set -e",
            "cmux_ssh_askpass_dir=$(mktemp -d \"${TMPDIR:-/tmp}/cmux-ssh-askpass.XXXXXX\")",
            "cmux_ssh_askpass_file=\"$cmux_ssh_askpass_dir/password\"",
            "cmux_ssh_askpass_script=\"$cmux_ssh_askpass_dir/askpass\"",
            "cmux_ssh_expect_script=\"$cmux_ssh_askpass_dir/ssh-password.exp\"",
            "cleanup() { rm -rf \"$cmux_ssh_askpass_dir\"; }",
            "trap cleanup EXIT HUP INT TERM",
            "printf %s \(shellQuote(passwordB64)) | base64 -d > \"$cmux_ssh_askpass_file\" 2>/dev/null || printf %s \(shellQuote(passwordB64)) | base64 -D > \"$cmux_ssh_askpass_file\"",
            "chmod 600 \"$cmux_ssh_askpass_file\"",
            "if command -v expect >/dev/null 2>&1; then",
            "  cat > \"$cmux_ssh_expect_script\" <<'CMUX_EXPECT'",
            "set timeout 12",
            "set password_file $env(CMUX_SSH_ASKPASS_FILE)",
            "set fh [open $password_file r]",
            "set password [read $fh]",
            "close $fh",
            "set password [string trimright $password \"\\r\\n\"]",
            "set cmux_interactive_stdin [expr {[catch {exec /bin/sh -c {test -t 0}}] == 0}]",
            "log_user 0",
            "spawn {*}$argv",
            "proc cmux_rejected_password {} {",
            "  puts stderr {\\n[cmux] Cloud VM SSH credential was rejected; reconnecting.}",
            "  catch {close}",
            "  catch {wait}",
            "  exit 255",
            "}",
            "proc cmux_relay_session {} {",
            "  global cmux_interactive_stdin",
            "  set timeout -1",
            "  log_user 1",
            "  if {$cmux_interactive_stdin} {",
            "    interact",
            "    set status [wait]",
            "    exit [lindex $status 3]",
            "  }",
            "  expect { eof { set status [wait]; exit [lindex $status 3] } }",
            "}",
            "proc cmux_wait_after_password {} {",
            "  set timeout 2",
            "  expect {",
            "    -re \"(?i)permission denied\" { cmux_rejected_password }",
            "    -re \"(?i)password:\" { cmux_rejected_password }",
            "    timeout {",
            "      set cmux_buffer \"\"",
            "      catch { set cmux_buffer $expect_out(buffer) }",
            "      if {[regexp -nocase {(password:|permission denied)} $cmux_buffer]} { cmux_rejected_password }",
            "      if {[string length $cmux_buffer] > 0} { send_user -- $cmux_buffer }",
            "      cmux_relay_session",
            "    }",
            "    eof { set status [wait]; exit [lindex $status 3] }",
            "  }",
            "}",
            "expect {",
            "  -re \"(?i)password:\" {",
            "    send -- \"$password\\r\"",
            "    cmux_wait_after_password",
            "  }",
            "  timeout {",
            "    puts stderr {\\n[cmux] Cloud VM SSH credential prompt timed out; reconnecting.}",
            "    exit 255",
            "  }",
            "  eof { set status [wait]; exit [lindex $status 3] }",
            "}",
            "set status [wait]",
            "exit [lindex $status 3]",
            "CMUX_EXPECT",
            "  chmod 700 \"$cmux_ssh_expect_script\"",
            "  export CMUX_SSH_ASKPASS_FILE=\"$cmux_ssh_askpass_file\"",
            "  set +e",
            "  expect \"$cmux_ssh_expect_script\" \"$@\"",
            "  cmux_ssh_status=$?",
            "  exit \"$cmux_ssh_status\"",
            "fi",
            "printf '%s\\n' '#!/bin/sh' 'cat \"$CMUX_SSH_ASKPASS_FILE\"' > \"$cmux_ssh_askpass_script\"",
            "chmod 700 \"$cmux_ssh_askpass_script\"",
            "export CMUX_SSH_ASKPASS_FILE=\"$cmux_ssh_askpass_file\"",
            "export SSH_ASKPASS=\"$cmux_ssh_askpass_script\"",
            "export SSH_ASKPASS_REQUIRE=force",
            "export DISPLAY=\"${DISPLAY:-cmux}\"",
            "set +e",
            "\"$@\"",
            "cmux_ssh_status=$?",
            "exit \"$cmux_ssh_status\"",
        ].joined(separator: "\n")
    }

    func sshAskpassExecShellScript(passwordFilePath: String, cleanupDirectory: String) -> String {
        [
            "set -e",
            "cmux_ssh_askpass_dir=\(shellQuote(cleanupDirectory))",
            "cmux_ssh_askpass_file=\(shellQuote(passwordFilePath))",
            "cmux_ssh_askpass_script=\"$cmux_ssh_askpass_dir/askpass\"",
            "cmux_ssh_expect_script=\"$cmux_ssh_askpass_dir/ssh-password.exp\"",
            "cleanup() { rm -rf \"$cmux_ssh_askpass_dir\"; }",
            "trap cleanup EXIT HUP INT TERM",
            "chmod 600 \"$cmux_ssh_askpass_file\"",
            "if command -v expect >/dev/null 2>&1; then",
            "  cat > \"$cmux_ssh_expect_script\" <<'CMUX_EXPECT'",
            "set timeout 12",
            "set password_file $env(CMUX_SSH_ASKPASS_FILE)",
            "set fh [open $password_file r]",
            "set password [read $fh]",
            "close $fh",
            "set password [string trimright $password \"\\r\\n\"]",
            "set cmux_interactive_stdin [expr {[catch {exec /bin/sh -c {test -t 0}}] == 0}]",
            "log_user 0",
            "spawn {*}$argv",
            "proc cmux_rejected_password {} {",
            "  puts stderr {\\n[cmux] Cloud VM SSH credential was rejected; reconnecting.}",
            "  catch {close}",
            "  catch {wait}",
            "  exit 255",
            "}",
            "proc cmux_relay_session {} {",
            "  global cmux_interactive_stdin",
            "  set timeout -1",
            "  log_user 1",
            "  if {$cmux_interactive_stdin} {",
            "    interact",
            "    set status [wait]",
            "    exit [lindex $status 3]",
            "  }",
            "  expect { eof { set status [wait]; exit [lindex $status 3] } }",
            "}",
            "proc cmux_wait_after_password {} {",
            "  set timeout 2",
            "  expect {",
            "    -re \"(?i)permission denied\" { cmux_rejected_password }",
            "    -re \"(?i)password:\" { cmux_rejected_password }",
            "    timeout {",
            "      set cmux_buffer \"\"",
            "      catch { set cmux_buffer $expect_out(buffer) }",
            "      if {[regexp -nocase {(password:|permission denied)} $cmux_buffer]} { cmux_rejected_password }",
            "      if {[string length $cmux_buffer] > 0} { send_user -- $cmux_buffer }",
            "      cmux_relay_session",
            "    }",
            "    eof { set status [wait]; exit [lindex $status 3] }",
            "  }",
            "}",
            "expect {",
            "  -re \"(?i)password:\" {",
            "    send -- \"$password\\r\"",
            "    cmux_wait_after_password",
            "  }",
            "  timeout {",
            "    puts stderr {\\n[cmux] Cloud VM SSH credential prompt timed out; reconnecting.}",
            "    exit 255",
            "  }",
            "  eof { set status [wait]; exit [lindex $status 3] }",
            "}",
            "set status [wait]",
            "exit [lindex $status 3]",
            "CMUX_EXPECT",
            "  chmod 700 \"$cmux_ssh_expect_script\"",
            "  export CMUX_SSH_ASKPASS_FILE=\"$cmux_ssh_askpass_file\"",
            "  set +e",
            "  expect \"$cmux_ssh_expect_script\" \"$@\"",
            "  cmux_ssh_status=$?",
            "  exit \"$cmux_ssh_status\"",
            "fi",
            "printf '%s\\n' '#!/bin/sh' 'cat \"$CMUX_SSH_ASKPASS_FILE\"' > \"$cmux_ssh_askpass_script\"",
            "chmod 700 \"$cmux_ssh_askpass_script\"",
            "export CMUX_SSH_ASKPASS_FILE=\"$cmux_ssh_askpass_file\"",
            "export SSH_ASKPASS=\"$cmux_ssh_askpass_script\"",
            "export SSH_ASKPASS_REQUIRE=force",
            "export DISPLAY=\"${DISPLAY:-cmux}\"",
            "set +e",
            "\"$@\"",
            "cmux_ssh_status=$?",
            "exit \"$cmux_ssh_status\"",
        ].joined(separator: "\n")
    }

    private func buildSSHStartupScriptBody(
        sshCommand: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        isShellSnippet: Bool,
        passwordCredential: String?,
        controlPathPreflightShellFunction: String?,
        oneTimeCommand: String?,
        retryPTYAttachStatus: Bool,
        reconnectLimitDefault: Int
    ) -> String {
        let trimmedFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)
        let shellFeaturesBootstrap: String = trimmedFeatures.isEmpty
            ? ""
            : "export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedFeatures))"
        let lifecycleCleanup = buildSSHSessionEndShellCommand(remoteRelayPort: remoteRelayPort)
        let lifecycleRetirement = retryPTYAttachStatus
            ? buildSSHSessionEndShellCommand(remoteRelayPort: remoteRelayPort, lifecycleOnly: true)
            : ":"
        let trimmedControlPathPreflight = controlPathPreflightShellFunction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOneTimeCommand = oneTimeCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOneTimeCommand = trimmedOneTimeCommand?.isEmpty == false
        var scriptLines: [String] = []
        if !shellFeaturesBootstrap.isEmpty {
            scriptLines.append(shellFeaturesBootstrap)
        }
        if let passwordCredential, !passwordCredential.isEmpty {
            let passwordB64 = Data(passwordCredential.utf8).base64EncodedString()
            scriptLines += [
                "cmux_ssh_askpass_dir=$(mktemp -d \"${TMPDIR:-/tmp}/cmux-ssh-askpass.XXXXXX\") || exit 1",
                "cmux_ssh_askpass_file=\"$cmux_ssh_askpass_dir/password\"",
                "cmux_ssh_askpass_script=\"$cmux_ssh_askpass_dir/askpass\"",
                "printf %s \(shellQuote(passwordB64)) | base64 -d > \"$cmux_ssh_askpass_file\" 2>/dev/null || printf %s \(shellQuote(passwordB64)) | base64 -D > \"$cmux_ssh_askpass_file\" || exit 1",
                "chmod 600 \"$cmux_ssh_askpass_file\"",
                "printf '%s\\n' '#!/bin/sh' 'cat \"$CMUX_SSH_ASKPASS_FILE\"' > \"$cmux_ssh_askpass_script\"",
                "chmod 700 \"$cmux_ssh_askpass_script\"",
                "export CMUX_SSH_ASKPASS_FILE=\"$cmux_ssh_askpass_file\"",
                "export SSH_ASKPASS=\"$cmux_ssh_askpass_script\"",
                "export SSH_ASKPASS_REQUIRE=force",
                "export DISPLAY=\"${DISPLAY:-cmux}\"",
                "cmux_ssh_cleanup_password() { rm -rf \"$cmux_ssh_askpass_dir\" 2>/dev/null || true; }",
            ]
        } else {
            scriptLines.append("cmux_ssh_cleanup_password() { :; }")
        }
        if retryPTYAttachStatus {
            scriptLines += [
                "CMUX_SSH_PTY_SESSION_ID=\"ssh-${CMUX_WORKSPACE_ID:-}-${CMUX_SURFACE_ID:-}\"",
                "CMUX_SSH_PTY_LIFECYCLE_ID=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]') || exit 1",
                "export CMUX_SSH_PTY_SESSION_ID CMUX_SSH_PTY_LIFECYCLE_ID",
            ]
        }
        if let trimmedControlPathPreflight, !trimmedControlPathPreflight.isEmpty {
            scriptLines.append(trimmedControlPathPreflight)
        }
        if let trimmedOneTimeCommand, !trimmedOneTimeCommand.isEmpty {
            scriptLines.append("trap 'cmux_ssh_cleanup_password' EXIT")
            scriptLines += ["cmux_ssh_foreground_auth() {", trimmedOneTimeCommand, "}"]
            scriptLines += ["( cmux_ssh_foreground_auth )", "cmux_ssh_auth_status=$?", "if [ \"$cmux_ssh_auth_status\" -ne 0 ]; then exit \"$cmux_ssh_auth_status\"; fi", "trap - EXIT"]
        }
        let reconnectConfiguration = retryPTYAttachStatus ? [
            "cmux_ssh_reconnect_limit=\"${CMUX_SSH_RECONNECT_LIMIT:-}\"",
            "case \"$cmux_ssh_reconnect_limit\" in '') cmux_ssh_reconnect_limit='∞'; cmux_ssh_reconnect_unbounded=1 ;; *[!0-9]*) cmux_ssh_reconnect_limit=20; cmux_ssh_reconnect_unbounded=0 ;; *) cmux_ssh_reconnect_unbounded=0 ;; esac",
            "cmux_ssh_reconnect_delay=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "case \"$cmux_ssh_reconnect_delay\" in ''|*[!0-9]*|0*) cmux_ssh_reconnect_delay=2 ;; esac",
            "cmux_ssh_reconnect_max_delay=\"${CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS:-30}\"",
            "case \"$cmux_ssh_reconnect_max_delay\" in ''|*[!0-9]*|0*) cmux_ssh_reconnect_max_delay=30 ;; esac",
            "if [ \"$cmux_ssh_reconnect_delay\" -gt \"$cmux_ssh_reconnect_max_delay\" ]; then cmux_ssh_reconnect_delay=\"$cmux_ssh_reconnect_max_delay\"; fi",
            "cmux_ssh_reconnect_initial_delay=\"$cmux_ssh_reconnect_delay\"",
        ] : [
            "cmux_ssh_reconnect_limit=\"${CMUX_SSH_RECONNECT_LIMIT:-\(max(0, reconnectLimitDefault))}\"",
            "case \"$cmux_ssh_reconnect_limit\" in ''|*[!0-9]*) cmux_ssh_reconnect_limit=20 ;; esac",
            "cmux_ssh_reconnect_delay=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "case \"$cmux_ssh_reconnect_delay\" in ''|*[!0-9]*) cmux_ssh_reconnect_delay=2 ;; esac",
            "if [ \"$cmux_ssh_reconnect_delay\" -lt 1 ]; then cmux_ssh_reconnect_delay=2; fi",
        ]
        scriptLines += [
            "rm -f -- \"$0\" 2>/dev/null || true",
            "CMUX_SSH_SESSION_ENDED=0",
            "CMUX_SSH_STARTUP_PID=$$",
            "export CMUX_SSH_STARTUP_PID",
        ] + reconnectConfiguration + [
            "cmux_ssh_retry=0",
            "cmux_ssh_reauth_required=0",
            "CMUX_SSH_CHILD_PID=",
            "CMUX_SSH_PENDING_SIGNAL=",
            "cmux_ssh_note() { if [ -t 2 ]; then printf \"$@\" >&2 || true; fi; }",
            "cmux_ssh_session_end() { if [ \"${CMUX_SSH_SESSION_ENDED:-0}\" = 1 ]; then return; fi; CMUX_SSH_SESSION_ENDED=1; cmux_ssh_cleanup_password; \(lifecycleCleanup); }",
            "cmux_ssh_signal_exit() { cmux_ssh_signal_status=\"$1\"; if [ -z \"${CMUX_SSH_CHILD_PID:-}\" ]; then CMUX_SSH_PENDING_SIGNAL=\"$cmux_ssh_signal_status\"; return; fi; CMUX_SSH_SESSION_ENDED=1; cmux_ssh_cleanup_password; \(lifecycleRetirement); trap - EXIT HUP INT TERM; exit \"$cmux_ssh_signal_status\"; }",
            "trap 'cmux_ssh_session_end' EXIT",
            "trap 'cmux_ssh_signal_exit 129' HUP",
            "trap 'cmux_ssh_signal_exit 130' INT",
            "trap 'cmux_ssh_signal_exit 143' TERM",
            "while :; do",
        ]
        if hasOneTimeCommand {
            scriptLines.append("  if [ \"$cmux_ssh_reauth_required\" -eq 1 ]; then")
            scriptLines += ["    ( cmux_ssh_foreground_auth )", "    cmux_ssh_status=$?", "    if [ \"$cmux_ssh_status\" -eq 0 ]; then cmux_ssh_reauth_required=0; elif [ \"$cmux_ssh_status\" -ne 255 ]; then break; fi", "  fi", "  if [ \"$cmux_ssh_reauth_required\" -eq 0 ]; then"]
        }
        if let trimmedControlPathPreflight, !trimmedControlPathPreflight.isEmpty,
           !hasOneTimeCommand {
            scriptLines.append("  cmux_ssh_preflight_control_path")
        }
        if retryPTYAttachStatus {
            // Advertise per attempt whether another 254|255 retry is queued so
            // ssh-pty-attach only suppresses its pty_attach_end cleanup while a
            // retry is actually pending; see CMUXCLI.sshPTYAttachWrapperRetryPending
            // and keep in sync with CMUXCLI.sshPTYAttachRetryLoopLines /
            // SSHPTYAttachStartupCommandBuilder.retryingAttachLines.
            scriptLines += [
                "  if [ \"$cmux_ssh_reconnect_unbounded\" -eq 1 ] || [ \"$cmux_ssh_retry\" -lt \"$cmux_ssh_reconnect_limit\" ]; then CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY=1; else CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY=0; fi",
                "  export CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY",
            ]
        }
        if isShellSnippet {
            scriptLines += [
                "  (",
                "    \(sshCommand)",
                "  ) <&0 &",
            ]
        } else {
            scriptLines.append("  command \(sshCommand) <&0 &")
        }
        let retryableStatusPattern = retryPTYAttachStatus ? "254|255" : "255"
        scriptLines += [
            "  CMUX_SSH_CHILD_PID=$!",
            "  if [ -n \"${CMUX_SSH_PENDING_SIGNAL:-}\" ]; then cmux_ssh_signal_exit \"$CMUX_SSH_PENDING_SIGNAL\"; fi",
            "  wait \"$CMUX_SSH_CHILD_PID\"",
            "  cmux_ssh_status=$?",
            "  CMUX_SSH_CHILD_PID=",
            "  if [ \"$cmux_ssh_status\" -eq 0 ]; then break; fi",
            "  case \"$cmux_ssh_status\" in \(retryableStatusPattern)) ;; *) break ;; esac",
        ]
        if retryPTYAttachStatus {
            scriptLines.append("  if [ \"$cmux_ssh_status\" -eq 254 ]; then cmux_ssh_reconnect_delay=\"$cmux_ssh_reconnect_initial_delay\"; fi")
        }
        if hasOneTimeCommand {
            scriptLines += ["  if [ \"$cmux_ssh_status\" -eq 255 ]; then cmux_ssh_reauth_required=1; fi", "  fi"]
        }
        let retryLimitCondition = retryPTYAttachStatus
            ? "  if [ \"$cmux_ssh_reconnect_unbounded\" -eq 0 ] && [ \"$cmux_ssh_retry\" -ge \"$cmux_ssh_reconnect_limit\" ]; then break; fi"
            : "  if [ \"$cmux_ssh_retry\" -ge \"$cmux_ssh_reconnect_limit\" ]; then break; fi"
        scriptLines.append(retryLimitCondition)
        scriptLines += [
            "  cmux_ssh_retry=$((cmux_ssh_retry + 1))",
            "  cmux_ssh_note '\\n\\033[33m[cmux] ssh exited with status %s; reconnecting (attempt %s/%s).\\033[0m\\n\\033[2m[cmux] close this pane or press Ctrl-C to stop reconnecting.\\033[0m\\n' \"$cmux_ssh_status\" \"$cmux_ssh_retry\" \"$cmux_ssh_reconnect_limit\"",
            "  if [ \"$cmux_ssh_reconnect_delay\" -gt 0 ]; then sleep \"$cmux_ssh_reconnect_delay\"; fi",
        ]
        if retryPTYAttachStatus {
            scriptLines.append("  if [ \"$cmux_ssh_reconnect_delay\" -lt \"$cmux_ssh_reconnect_max_delay\" ]; then cmux_ssh_reconnect_delay=$((cmux_ssh_reconnect_delay * 2)); if [ \"$cmux_ssh_reconnect_delay\" -gt \"$cmux_ssh_reconnect_max_delay\" ]; then cmux_ssh_reconnect_delay=\"$cmux_ssh_reconnect_max_delay\"; fi; fi")
        }
        scriptLines += [
            "  if [ -n \"${CMUX_SSH_PENDING_SIGNAL:-}\" ]; then cmux_ssh_session_end; trap - EXIT HUP INT TERM; exit \"$CMUX_SSH_PENDING_SIGNAL\"; fi",
            "done",
            "trap - EXIT HUP INT TERM",
            "cmux_ssh_session_end",
            "if [ \"$cmux_ssh_status\" -ne 0 ]; then",
            "  printf '\\n\\033[31m[cmux] ssh exited with status %s.\\033[0m\\n\\033[2m[cmux] the remote VM may have been paused, destroyed, or lost network.\\033[0m\\n\\033[2m[cmux] press Enter to close this pane.\\033[0m\\n' \"$cmux_ssh_status\" >&2 || true",
            "  IFS= read -r _cmux_dismiss_key 2>/dev/null || true",
            "fi",
            "exit $cmux_ssh_status",
        ]
        return scriptLines.joined(separator: "\n")
    }
    private func writeSSHStartupScript(_ scriptBody: String, remoteRelayPort: Int) throws -> String {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-startup-\(remoteRelayPort)-\(UUID().uuidString.lowercased()).sh"
        )
        let script = "#!/bin/sh\n\(scriptBody)\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return shellQuote(scriptURL.path)
    }
    private func reusableShellStartupCommand(
        scriptBody: String,
        tempPrefix: String
    ) -> String {
        let fullScript = "#!/bin/sh\n\(scriptBody)\n"
        let encodedScript = Data(fullScript.utf8).base64EncodedString()
        let encodedLiteral = shellQuote(encodedScript)
        let wrapper = [
            "cmux_tmp=$(mktemp \"${TMPDIR:-/tmp}/\(tempPrefix).XXXXXX\") || exit 1",
            "cmux_cleanup() { rm -f -- \"$cmux_tmp\" 2>/dev/null || true; }",
            "trap 'cmux_cleanup' EXIT HUP INT TERM",
            "(printf %s \(encodedLiteral) | base64 -d 2>/dev/null || printf %s \(encodedLiteral) | base64 -D 2>/dev/null) > \"$cmux_tmp\" || exit 1",
            "chmod 700 \"$cmux_tmp\" >/dev/null 2>&1 || true",
            "/bin/sh \"$cmux_tmp\"",
            "cmux_status=$?",
            "trap - EXIT HUP INT TERM",
            "cmux_cleanup",
            "unset cmux_tmp cmux_status",
            "unset -f cmux_cleanup 2>/dev/null || true",
            "exit $cmux_status",
        ].joined(separator: "\n")
        return "/bin/sh -c \(shellQuote(wrapper))"
    }

    private func buildSSHSessionEndShellCommand(
        remoteRelayPort: Int,
        lifecycleOnly: Bool = false
    ) -> String {
        let lifecycleOnlyFlag = lifecycleOnly ? " --lifecycle-only" : ""
        return [
            "if [ -n \"${CMUX_BUNDLED_CLI_PATH:-}\" ]",
            "&& [ -x \"${CMUX_BUNDLED_CLI_PATH}\" ]",
            "&& [ -n \"${CMUX_SOCKET_PATH:-}\" ]",
            "&& [ -n \"${CMUX_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${CMUX_SURFACE_ID:-}\" ]; then",
            "\"${CMUX_BUNDLED_CLI_PATH}\" --socket \"${CMUX_SOCKET_PATH}\" ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${CMUX_WORKSPACE_ID}\" --surface \"${CMUX_SURFACE_ID}\" --session-id \"${CMUX_SSH_PTY_SESSION_ID:-}\" --lifecycle-id \"${CMUX_SSH_PTY_LIFECYCLE_ID:-}\"\(lifecycleOnlyFlag) >/dev/null 2>&1 || true;",
            "elif command -v cmux >/dev/null 2>&1",
            "&& [ -n \"${CMUX_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${CMUX_SURFACE_ID:-}\" ]; then",
            "cmux ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${CMUX_WORKSPACE_ID}\" --surface \"${CMUX_SURFACE_ID}\" --session-id \"${CMUX_SSH_PTY_SESSION_ID:-}\" --lifecycle-id \"${CMUX_SSH_PTY_LIFECYCLE_ID:-}\"\(lifecycleOnlyFlag) >/dev/null 2>&1 || true;",
            "fi",
        ].joined(separator: " ")
    }
}
