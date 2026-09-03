import Foundation

/// Builds the shell runner that supplies a stored credential to an SSH process.
struct SSHAskpassExecShellScript: Sendable {
    let passwordFilePath: String
    let cleanupDirectory: String

    var text: String {
        [
            "set -e",
            "cmux_ssh_askpass_dir=\(Self.shellQuote(cleanupDirectory))",
            "cmux_ssh_askpass_file=\(Self.shellQuote(passwordFilePath))",
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

    private static func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
