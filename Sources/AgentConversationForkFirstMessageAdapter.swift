import Foundation

/// Starts a harness in a child PTY and asks for an explicit confirmation before
/// submitting a private transfer. Harness output only decides when to offer the
/// confirmation; it never authorizes disclosure on its own.
struct AgentConversationForkFirstMessageAdapter {
    private static let heredocDelimiter = "CMUX_CONVERSATION_FIRST_MESSAGE"
    private static let blockingPromptPattern = #"(?i)(authentication required|enter .*api key|sign[ -]?in|log[ -]?in|login required|trust (this|the|these)|hooks need review|update (available|required)|upgrade now|must update|migration required|complete (setup|onboarding)|choose .*account)"#

    static func startupCommand(
        interactiveCommand: String,
        firstMessage: String,
        readinessPattern: String,
        recipientExecutablePath: String
    ) -> String {
        let encodedCommand = hexEncoded(interactiveCommand)
        let encodedMessage = hexEncoded(firstMessage)
        let encodedReadinessPattern = hexEncoded(readinessPattern)
        let encodedBlockingPromptPattern = hexEncoded(blockingPromptPattern)
        let confirmationFormat = String(
            localized: "forkConversation.transfer.confirmation",
            defaultValue: "cmux: The running harness was launched from %@ and may load other code from that installation. Press Control-] to send the transferred conversation, or Control-X to continue without it."
        )
        let confirmationPrompt = String(
            format: confirmationFormat,
            locale: .current,
            terminalSafePath(recipientExecutablePath)
        )
        let encodedConfirmationPrompt = hexEncoded(confirmationPrompt)
        return """
        [[ -x /usr/bin/expect ]] || exit 127
        /usr/bin/expect -f /dev/fd/3 3<<'\(heredocDelimiter)'
        set cmux_command [encoding convertfrom utf-8 [binary format H* {\(encodedCommand)}]]
        set cmux_message [encoding convertfrom utf-8 [binary format H* {\(encodedMessage)}]]
        set cmux_readiness_pattern [encoding convertfrom utf-8 [binary format H* {\(encodedReadinessPattern)}]]
        set cmux_blocking_pattern [encoding convertfrom utf-8 [binary format H* {\(encodedBlockingPromptPattern)}]]
        set cmux_confirmation_prompt [encoding convertfrom utf-8 [binary format H* {\(encodedConfirmationPrompt)}]]
        set cmux_sent 0
        set cmux_abandoned 0
        set cmux_blocked 0
        set cmux_confirmation_pending 0
        set cmux_user_eof 0
        set cmux_ready_timer ""
        set cmux_fallback_timer ""
        set cmux_deadline_timer ""

        proc cmux_cancel_confirmation {} {
          global cmux_confirmation_pending cmux_ready_timer
          if {$cmux_ready_timer ne ""} {
            after cancel $cmux_ready_timer
            set cmux_ready_timer ""
          }
          set cmux_confirmation_pending 0
        }

        proc cmux_cancel_fallback {} {
          global cmux_fallback_timer
          if {$cmux_fallback_timer ne ""} {
            after cancel $cmux_fallback_timer
            set cmux_fallback_timer ""
          }
        }

        proc cmux_abandon_submission {} {
          global cmux_abandoned cmux_deadline_timer cmux_sent
          if {$cmux_sent || $cmux_abandoned} { return }
          cmux_cancel_confirmation
          cmux_cancel_fallback
          set cmux_abandoned 1
          if {$cmux_deadline_timer ne ""} {
            after cancel $cmux_deadline_timer
            set cmux_deadline_timer ""
          }
        }

        proc cmux_request_confirmation {} {
          global cmux_abandoned cmux_blocked cmux_confirmation_pending cmux_confirmation_prompt
          global cmux_sent cmux_user_eof
          if {$cmux_sent || $cmux_abandoned || $cmux_blocked || $cmux_confirmation_pending} { return }
          cmux_cancel_confirmation
          cmux_cancel_fallback
          if {$cmux_user_eof} {
            cmux_abandon_submission
            return
          }
          set cmux_confirmation_pending 1
          send_user -- "\r\n$cmux_confirmation_prompt\r\n"
        }

        proc cmux_submit_message {} {
          global cmux_abandoned cmux_blocked cmux_confirmation_pending cmux_deadline_timer
          global cmux_message cmux_sent spawn_id
          if {$cmux_sent || $cmux_abandoned || $cmux_blocked || !$cmux_confirmation_pending} { return }
          cmux_cancel_confirmation
          cmux_cancel_fallback
          set cmux_sent 1
          if {$cmux_deadline_timer ne ""} {
            after cancel $cmux_deadline_timer
            set cmux_deadline_timer ""
          }
          send -i $spawn_id -- "\\033\\[200~"
          send -i $spawn_id -- $cmux_message
          send -i $spawn_id -- "\\033\\[201~\\r"
        }

        proc cmux_schedule_confirmation {} {
          global cmux_abandoned cmux_blocked cmux_confirmation_pending cmux_ready_timer cmux_sent
          if {$cmux_sent || $cmux_abandoned || $cmux_confirmation_pending} { return }
          set cmux_blocked 0
          cmux_cancel_confirmation
          set cmux_ready_timer [after 750 cmux_request_confirmation]
        }

        proc cmux_schedule_fallback {} {
          global cmux_abandoned cmux_blocked cmux_confirmation_pending cmux_fallback_timer cmux_sent
          if {$cmux_sent || $cmux_abandoned || $cmux_blocked || $cmux_confirmation_pending} { return }
          cmux_cancel_fallback
          set cmux_fallback_timer [after 2500 cmux_request_confirmation]
        }

        proc cmux_blocking_prompt {} {
          global cmux_blocked
          set cmux_blocked 1
          cmux_cancel_confirmation
          cmux_cancel_fallback
        }

        proc cmux_deadline_reached {} {
          cmux_abandon_submission
        }

        spawn -noecho /bin/zsh -lc $cmux_command
        cmux_schedule_fallback
        if {[catch {stty -g}]} {
          set timeout 300
          while {!$cmux_sent && !$cmux_abandoned} {
            expect {
              -i $spawn_id -re $cmux_blocking_pattern { cmux_blocking_prompt }
              -i $spawn_id -re $cmux_readiness_pattern { cmux_schedule_confirmation }
              -i $user_spawn_id "\\035" {
                if {$cmux_confirmation_pending} { cmux_submit_message }
              }
              -i $user_spawn_id "\\030" { cmux_abandon_submission }
              -i $user_spawn_id eof {
                set cmux_user_eof 1
                cmux_abandon_submission
              }
              -i $spawn_id timeout { cmux_abandon_submission }
              -i $spawn_id eof { break }
            }
          }
          if {$cmux_sent || $cmux_abandoned} {
            expect -i $spawn_id eof
          }
        } else {
          set cmux_deadline_timer [after 300000 cmux_deadline_reached]
          interact {
            "\\035" {
              if {$cmux_confirmation_pending} {
                cmux_submit_message
              } else {
                send -i $spawn_id -- "\\035"
              }
            }
            "\\030" {
              if {$cmux_confirmation_pending} {
                cmux_abandon_submission
              } else {
                send -i $spawn_id -- "\\030"
              }
            }
            -o
            -nobuffer -re $cmux_blocking_pattern { cmux_blocking_prompt }
            -nobuffer -re $cmux_readiness_pattern { cmux_schedule_confirmation }
          }
        }
        if {!$cmux_sent} { exit 75 }
        set cmux_wait [wait]
        exit [lindex $cmux_wait 3]
        \(heredocDelimiter)
        """
    }

    private static func hexEncoded(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    /// Prevents an attacker-controlled filename from emitting terminal control
    /// sequences while preserving ordinary absolute paths verbatim.
    private static func terminalSafePath(_ path: String) -> String {
        path.unicodeScalars.reduce(into: "") { result, scalar in
            switch scalar.value {
            case 0...31, 127...159, 0x202A...0x202E, 0x2066...0x2069:
                result += String(format: "\\u{%X}", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
    }
}
