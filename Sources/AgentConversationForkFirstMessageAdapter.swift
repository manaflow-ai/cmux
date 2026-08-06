import Foundation

/// Starts a harness in a child PTY and submits a private transfer only after
/// the harness renders its own editor. Authentication, trust, migration, and
/// update prompts remain interactive and cancel pending submission.
struct AgentConversationForkFirstMessageAdapter {
    private static let heredocDelimiter = "CMUX_CONVERSATION_FIRST_MESSAGE"
    private static let blockingPromptPattern = #"(?i)(authentication required|enter .*api key|sign[ -]?in|log[ -]?in|login required|trust (this|the|these)|hooks need review|update required|must update|migration required|complete (setup|onboarding)|choose .*account)"#

    static func startupCommand(
        interactiveCommand: String,
        firstMessage: String,
        readinessPattern: String
    ) -> String {
        let encodedCommand = hexEncoded(interactiveCommand)
        let encodedMessage = hexEncoded(firstMessage)
        let encodedReadinessPattern = hexEncoded(readinessPattern)
        let encodedBlockingPromptPattern = hexEncoded(blockingPromptPattern)
        return """
        [[ -x /usr/bin/expect ]] || exit 127
        /usr/bin/expect -f /dev/fd/3 3<<'\(heredocDelimiter)'
        set cmux_command [encoding convertfrom utf-8 [binary format H* {\(encodedCommand)}]]
        set cmux_message [encoding convertfrom utf-8 [binary format H* {\(encodedMessage)}]]
        set cmux_readiness_pattern [encoding convertfrom utf-8 [binary format H* {\(encodedReadinessPattern)}]]
        set cmux_blocking_pattern [encoding convertfrom utf-8 [binary format H* {\(encodedBlockingPromptPattern)}]]
        set cmux_sent 0
        set cmux_ready_timer ""
        set cmux_deadline_timer ""

        proc cmux_cancel_submission {} {
          global cmux_ready_timer
          if {$cmux_ready_timer ne ""} {
            after cancel $cmux_ready_timer
            set cmux_ready_timer ""
          }
        }

        proc cmux_submit_message {} {
          global cmux_deadline_timer cmux_message cmux_ready_timer cmux_sent spawn_id
          if {$cmux_sent} { return }
          set cmux_ready_timer ""
          set cmux_sent 1
          if {$cmux_deadline_timer ne ""} {
            after cancel $cmux_deadline_timer
            set cmux_deadline_timer ""
          }
          send -i $spawn_id -- "\\033\\[200~"
          send -i $spawn_id -- $cmux_message
          send -i $spawn_id -- "\\033\\[201~\\r"
        }

        proc cmux_schedule_submission {} {
          global cmux_ready_timer cmux_sent
          if {$cmux_sent} { return }
          cmux_cancel_submission
          set cmux_ready_timer [after 750 cmux_submit_message]
        }

        proc cmux_deadline_reached {} {
          global cmux_sent
          if {!$cmux_sent} { exit 75 }
        }

        spawn -noecho /bin/zsh -lc $cmux_command
        if {[catch {stty -g}]} {
          set timeout 300
          while {!$cmux_sent} {
            expect {
              -re $cmux_blocking_pattern { cmux_cancel_submission }
              -re $cmux_readiness_pattern {
                set timeout 1
                expect {
                  -re $cmux_blocking_pattern {
                    cmux_cancel_submission
                    set timeout 300
                  }
                  timeout { cmux_submit_message }
                  eof { exit 75 }
                }
              }
              timeout { exit 75 }
              eof { exit 75 }
            }
          }
          expect eof
        } else {
          set cmux_deadline_timer [after 300000 cmux_deadline_reached]
          interact {
            -o
            -nobuffer -re $cmux_blocking_pattern { cmux_cancel_submission }
            -nobuffer -re $cmux_readiness_pattern { cmux_schedule_submission }
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
}
