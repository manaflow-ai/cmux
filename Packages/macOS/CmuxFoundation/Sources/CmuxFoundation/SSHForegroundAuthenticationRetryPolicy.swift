internal import Foundation

/// Classifies foreground SSH authentication failures without hiding interactive
/// prompts or retrying permanent authentication and configuration errors.
///
/// OpenSSH uses status 255 for both transport outages and permanent failures.
/// The persistent PTY wrappers therefore need stderr context before deciding
/// whether an initial authentication attempt belongs in their reconnect loop.
public struct SSHForegroundAuthenticationRetryPolicy: Sendable {
    static let groupStateFileNames = [
        "identity",
        "identity.new",
        "created",
        "created.new",
        "publisher",
        "publisher.new",
        "anchor",
        "cancel",
        "processes",
        "processes.stopped",
        "owned",
        "owned.next",
        "groups",
        "groups.next",
        "groups.resume",
        "frozen",
        "individuals",
        "ordered",
        "signaled.groups",
        "signaled.pids",
        "reaper.failed",
        "reaper.failed.new",
        "orphaned",
        "orphaned.new",
    ]

    static let reaperLockStateFileNames = [
        "owner",
        "owner.new",
        "publisher",
        "publisher.new",
    ]

    /// Maximum consecutive transport failures before foreground auth surfaces the outage.
    public let maximumConsecutiveTransientFailures = 20

    /// Internal shell status for a status-255 failure with no recognized diagnostic.
    ///
    /// Callers surface this as 255 without retrying. Only a recognized transient
    /// transport diagnostic enters the foreground-authentication reconnect loop.
    public let unclassifiedFailureExitStatus = 252

    private let transientFailurePattern: String
    private let permanentFailurePattern: String

    /// Creates the policy used by cmux's foreground SSH authentication wrappers.
    public init() {
        transientFailurePattern = [
            "network is unreachable",
            "network is down",
            "no route to host",
            "host is down",
            "operation timed out",
            "connection timed out",
            "connection to .* timed out",
            "timeout, server .* not responding",
            "connection refused",
            "connection reset by peer",
            "connection reset by .* port [0-9]+",
            "connection closed by remote host",
            "connection closed by .* port [0-9]+",
            "connection to .* closed by remote host",
            "temporary failure in name resolution",
            "connection to .* port [0-9]+: broken pipe",
        ].joined(separator: "|")
        permanentFailurePattern = [
            "[^[:space:]]+@[^[:space:]]+: permission denied",
            "(zsh|bash|sh|dash|ksh|fish|csh|tcsh|env):.*permission denied",
            "host key verification failed",
            "remote host identification has changed",
            "authentication failed",
            "too many authentication failures",
            "bad configuration option",
            "no matching host key type found",
            "no matching cipher found",
            "no matching mac found",
            "no matching key exchange method found",
            "name or service not known",
            "nodename nor servname provided",
            "command not found",
            "(^|[^[:alnum:]_])(zsh|bash|sh|dash|ksh|fish|csh|tcsh|env):.*no such file or directory",
            "bad interpreter",
            "exec format error",
        ].joined(separator: "|")
    }

    /// Builds the final removal command for a reaped authentication attempt's bounded state.
    ///
    /// Callers run this only after the authentication root has exited, when no late
    /// publisher can still require the cancellation marker.
    ///
    /// - Returns: A shell command that removes every file owned by the group-state protocol.
    public func processGroupStateRemovalShellCommand() -> String {
        let reaperLockStateArguments = Self.reaperLockStateFileNames
            .map { "\"$CMUX_SSH_AUTH_GROUP_DIR/reaper.lock/\($0)\"" }
            .joined(separator: " ")
        return [
            "/bin/rm -f -- \(reaperLockStateArguments) 2>/dev/null || true",
            "/bin/rmdir \"$CMUX_SSH_AUTH_GROUP_DIR/reaper.lock\" 2>/dev/null || true",
            groupStateFileRemovalShellCommand(includingCancellationMarker: true),
        ].joined(separator: "; ")
    }

    /// Builds the shared cleanup body for one authentication group directory.
    ///
    /// The caller wraps this body in its entrypoint-specific shell function.
    /// Published process ownership is terminated before bounded state is removed,
    /// and a live reaper retains the directory until it finishes.
    ///
    /// - Parameter terminatesPublishedGroup: Whether this entrypoint runs foreground authentication.
    /// - Returns: A shell function body that consumes `CMUX_SSH_AUTH_GROUP_DIR`.
    public func authenticationGroupDirectoryCleanupShellBody(
        terminatesPublishedGroup: Bool
    ) -> String {
        let publishedCleanup = terminatesPublishedGroup
            ? publishedAuthenticationCleanupShellCommand()
            : ":"
        return "if [ -n \"${CMUX_SSH_AUTH_GROUP_DIR:-}\" ]; then \(publishedCleanup); if [ ! -s \"$CMUX_SSH_AUTH_GROUP_DIR/identity\" ]; then \(processGroupStateRemovalShellCommand()); /bin/rmdir \"$CMUX_SSH_AUTH_GROUP_DIR\" 2>/dev/null || true; fi; fi; CMUX_SSH_AUTH_GROUP_DIR=; export CMUX_SSH_AUTH_GROUP_DIR;"
    }

    private func publishedAuthenticationCleanupShellCommand() -> String {
        "if [ -s \"$CMUX_SSH_AUTH_GROUP_DIR/identity\" ]; then cmux_ssh_terminate_owned_auth_group; if [ -s \"$CMUX_SSH_AUTH_GROUP_DIR/identity\" ]; then cmux_ssh_launch_owned_auth_group_reaper \"$CMUX_SSH_AUTH_GROUP_DIR\"; fi; fi"
    }

    private func groupStateFileRemovalShellCommand(
        includingCancellationMarker: Bool
    ) -> String {
        let fileNames = Self.groupStateFileNames.filter {
            includingCancellationMarker || $0 != "cancel"
        }
        let arguments = fileNames
            .map { "\"$CMUX_SSH_AUTH_GROUP_DIR/\($0)\"" }
            .joined(separator: " ")
        return "/bin/rm -f -- \(arguments) 2>/dev/null || true"
    }

    /// Builds the bounded helper that terminates foreground SSH authentication.
    ///
    /// The classifier publishes a signal-resistant anchor in its isolated PTY
    /// process group. Cleanup validates the anchor and group identities, freezes
    /// the bounded descendant closure, then KILLs every owned group. The shared
    /// wrapper PID is KILLed only while its original identity still matches.
    ///
    /// - Returns: Shell functions that terminate the owned group and outer tree.
    public func processTreeTerminationShellFunction() -> String {
        #"""
        cmux_ssh_auth_identity() {
          /usr/bin/env LC_ALL=C LANG=C /bin/ps -o ppid= -o pgid= -o state= -o lstart= -p "$1" 2>/dev/null | \
            /usr/bin/awk 'NF >= 8 && $3 !~ /Z/ {
              cmux_started = $4 "_" $5 "_" $6 "_" $7 "_" $8
              print $1 "|" $2 "|" cmux_started
            }'
        }

        cmux_ssh_auth_stopped_identity() {
          /usr/bin/env LC_ALL=C LANG=C /bin/ps -o ppid= -o pgid= -o state= -o lstart= -p "$1" 2>/dev/null | \
            /usr/bin/awk 'NF >= 8 && $3 ~ /T/ && $3 !~ /Z/ {
              cmux_started = $4 "_" $5 "_" $6 "_" $7 "_" $8
              print $1 "|" $2 "|" cmux_started
            }'
        }

        \#(ownedProcessGroupTerminationShellFunctions())

        cmux_ssh_auth_recorded_process_is_live() {
          cmux_ssh_auth_record_file="$1"
          if [ ! -s "$cmux_ssh_auth_record_file" ]; then return 1; fi
          cmux_ssh_auth_record=$(/bin/cat -- "$cmux_ssh_auth_record_file" 2>/dev/null || true)
          cmux_ssh_auth_record_pid=${cmux_ssh_auth_record%%|*}
          cmux_ssh_auth_record_identity=${cmux_ssh_auth_record#*|}
          if [ "$cmux_ssh_auth_record_identity" = "$cmux_ssh_auth_record" ]; then return 1; fi
          cmux_ssh_auth_record_parent=${cmux_ssh_auth_record_identity%%|*}
          cmux_ssh_auth_record_remainder=${cmux_ssh_auth_record_identity#*|}
          cmux_ssh_auth_record_group=${cmux_ssh_auth_record_remainder%%|*}
          cmux_ssh_auth_record_started=${cmux_ssh_auth_record_remainder#*|}
          case "$cmux_ssh_auth_record_pid" in ''|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_record_parent" in ''|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_record_group" in ''|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_record_started" in ''|*[!A-Za-z0-9_:]*) return 1 ;; esac
          [ "$(cmux_ssh_auth_identity "$cmux_ssh_auth_record_pid")" = \
            "$cmux_ssh_auth_record_identity" ]
        }

        cmux_ssh_auth_group_publisher_is_live() {
          cmux_ssh_auth_publisher_group_dir="$1"
          if cmux_ssh_auth_recorded_process_is_live \
            "$cmux_ssh_auth_publisher_group_dir/publisher" || \
            cmux_ssh_auth_recorded_process_is_live \
              "$cmux_ssh_auth_publisher_group_dir/publisher.new"; then
            return 0
          fi

          if [ ! -s "$cmux_ssh_auth_publisher_group_dir/identity" ]; then return 1; fi
          cmux_ssh_auth_publisher_group_identity=$(/bin/cat -- \
            "$cmux_ssh_auth_publisher_group_dir/identity" 2>/dev/null || true)
          cmux_ssh_auth_publisher_anchor=${cmux_ssh_auth_publisher_group_identity%%|*}
          cmux_ssh_auth_publisher_remainder=${cmux_ssh_auth_publisher_group_identity#*|}
          cmux_ssh_auth_publisher_group=${cmux_ssh_auth_publisher_remainder%%|*}
          cmux_ssh_auth_publisher_started=${cmux_ssh_auth_publisher_remainder#*|}
          case "$cmux_ssh_auth_publisher_anchor:$cmux_ssh_auth_publisher_group:$cmux_ssh_auth_publisher_started" in
            *[!A-Za-z0-9_:]*|:*|*:) return 1 ;;
          esac

          cmux_ssh_auth_publisher_anchor_identity=$(cmux_ssh_auth_identity \
            "$cmux_ssh_auth_publisher_anchor")
          cmux_ssh_auth_publisher_parent=${cmux_ssh_auth_publisher_anchor_identity%%|*}
          cmux_ssh_auth_publisher_anchor_remainder=${cmux_ssh_auth_publisher_anchor_identity#*|}
          cmux_ssh_auth_publisher_observed_group=${cmux_ssh_auth_publisher_anchor_remainder%%|*}
          cmux_ssh_auth_publisher_observed_started=${cmux_ssh_auth_publisher_anchor_remainder#*|}
          case "$cmux_ssh_auth_publisher_parent" in ''|0|1|*[!0-9]*) return 1 ;; esac
          [ "$cmux_ssh_auth_publisher_observed_group" = \
            "$cmux_ssh_auth_publisher_group" ] && \
            [ "$cmux_ssh_auth_publisher_observed_started" = \
              "$cmux_ssh_auth_publisher_started" ]
        }

        cmux_ssh_auth_reclaim_stale_reaper_lock() {
          cmux_ssh_auth_stale_lock="$1"
          if [ ! -d "$cmux_ssh_auth_stale_lock" ]; then return 0; fi
          if cmux_ssh_auth_recorded_process_is_live "$cmux_ssh_auth_stale_lock/owner" || \
            cmux_ssh_auth_recorded_process_is_live "$cmux_ssh_auth_stale_lock/publisher"; then
            return 1
          fi
          /bin/rm -f -- "$cmux_ssh_auth_stale_lock/owner" \
            "$cmux_ssh_auth_stale_lock/owner.new" \
            "$cmux_ssh_auth_stale_lock/publisher" \
            "$cmux_ssh_auth_stale_lock/publisher.new" 2>/dev/null || true
          /bin/rmdir "$cmux_ssh_auth_stale_lock" 2>/dev/null
        }

        cmux_ssh_auth_group_anchor_is_live() {
          cmux_ssh_auth_anchor_group_dir="$1"
          cmux_ssh_auth_anchor_record=$(/bin/cat -- \
            "$cmux_ssh_auth_anchor_group_dir/identity" 2>/dev/null || true)
          cmux_ssh_auth_anchor_pid=${cmux_ssh_auth_anchor_record%%|*}
          cmux_ssh_auth_anchor_remainder=${cmux_ssh_auth_anchor_record#*|}
          cmux_ssh_auth_anchor_group=${cmux_ssh_auth_anchor_remainder%%|*}
          cmux_ssh_auth_anchor_started=${cmux_ssh_auth_anchor_remainder#*|}
          case "$cmux_ssh_auth_anchor_pid" in ''|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_anchor_group" in ''|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_anchor_started" in ''|*[!A-Za-z0-9_:]*) return 1 ;; esac
          cmux_ssh_auth_anchor_identity=$(cmux_ssh_auth_identity \
            "$cmux_ssh_auth_anchor_pid")
          cmux_ssh_auth_anchor_observed_remainder=${cmux_ssh_auth_anchor_identity#*|}
          cmux_ssh_auth_anchor_observed_group=${cmux_ssh_auth_anchor_observed_remainder%%|*}
          cmux_ssh_auth_anchor_observed_started=${cmux_ssh_auth_anchor_observed_remainder#*|}
          [ "$cmux_ssh_auth_anchor_observed_group" = "$cmux_ssh_auth_anchor_group" ] && \
            [ "$cmux_ssh_auth_anchor_observed_started" = "$cmux_ssh_auth_anchor_started" ]
        }

        cmux_ssh_auth_group_orphan_retention_expired() {
          # Never signal an unverifiable PID or process group: it may have been
          # reused. Quarantine the bounded ownership record from the first
          # confirmed publisher-and-anchor absence, then reclaim it after one day.
          cmux_ssh_auth_orphan_group_dir="$1"
          cmux_ssh_auth_orphan_now=$(/bin/date +%s 2>/dev/null || true)
          cmux_ssh_auth_orphaned_at=$(/bin/cat -- \
            "$cmux_ssh_auth_orphan_group_dir/orphaned" 2>/dev/null || true)
          case "$cmux_ssh_auth_orphan_now" in ''|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_orphaned_at" in ''|*[!0-9]*)
            cmux_ssh_auth_orphaned_at=
            ;;
          esac
          if [ "${#cmux_ssh_auth_orphaned_at}" -gt 12 ]; then
            cmux_ssh_auth_orphaned_at=
          elif [ -n "$cmux_ssh_auth_orphaned_at" ] && \
            [ "$cmux_ssh_auth_orphaned_at" -gt "$cmux_ssh_auth_orphan_now" ]; then
            cmux_ssh_auth_orphaned_at=
          fi
          if [ -z "$cmux_ssh_auth_orphaned_at" ]; then
            (umask 077; printf '%s\n' "$cmux_ssh_auth_orphan_now" \
              > "$cmux_ssh_auth_orphan_group_dir/orphaned.new") 2>/dev/null && \
              /bin/mv -f -- "$cmux_ssh_auth_orphan_group_dir/orphaned.new" \
                "$cmux_ssh_auth_orphan_group_dir/orphaned" 2>/dev/null || true
            return 1
          fi
          [ $((cmux_ssh_auth_orphan_now - cmux_ssh_auth_orphaned_at)) -ge 86400 ]
        }

        cmux_ssh_auth_group_creation_retention_expired() {
          cmux_ssh_auth_created_group_dir="$1"
          cmux_ssh_auth_created_now=$(/bin/date +%s 2>/dev/null || true)
          cmux_ssh_auth_created_at=$(/bin/cat -- \
            "$cmux_ssh_auth_created_group_dir/created" 2>/dev/null || true)
          case "$cmux_ssh_auth_created_now" in ''|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_created_at" in ''|*[!0-9]*)
            cmux_ssh_auth_created_at=
            ;;
          esac
          if [ "${#cmux_ssh_auth_created_at}" -gt 12 ]; then
            cmux_ssh_auth_created_at=
          elif [ -n "$cmux_ssh_auth_created_at" ] && \
            [ "$cmux_ssh_auth_created_at" -gt "$cmux_ssh_auth_created_now" ]; then
            cmux_ssh_auth_created_at=
          fi
          if [ -z "$cmux_ssh_auth_created_at" ]; then
            (umask 077; printf '%s\n' "$cmux_ssh_auth_created_now" \
              > "$cmux_ssh_auth_created_group_dir/created.new") 2>/dev/null && \
              /bin/mv -f -- "$cmux_ssh_auth_created_group_dir/created.new" \
                "$cmux_ssh_auth_created_group_dir/created" 2>/dev/null || true
            return 1
          fi
          [ $((cmux_ssh_auth_created_now - cmux_ssh_auth_created_at)) -ge 86400 ]
        }

        cmux_ssh_launch_owned_auth_group_reaper() {
          CMUX_SSH_AUTH_REAPER_LAUNCHED=0
          cmux_ssh_auth_reaper_group_dir="$1"
          cmux_ssh_auth_reaper_expected_dir_identity="$(/usr/bin/id -u):700"
          cmux_ssh_auth_reaper_observed_dir_identity=$(/usr/bin/stat -f '%u:%Lp' \
            "$cmux_ssh_auth_reaper_group_dir" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_reaper_observed_dir_identity" != \
            "$cmux_ssh_auth_reaper_expected_dir_identity" ]; then return 0; fi
          if [ ! -s "$cmux_ssh_auth_reaper_group_dir/identity" ]; then return 0; fi
          cmux_ssh_auth_reaper_caller_group=$(/usr/bin/env LC_ALL=C LANG=C \
            /bin/ps -o pgid= -p "$$" 2>/dev/null | /usr/bin/tr -d '[:space:]')
          case "$cmux_ssh_auth_reaper_caller_group" in ''|*[!0-9]*) return 0 ;; esac
          cmux_ssh_auth_reaper_lock="$cmux_ssh_auth_reaper_group_dir/reaper.lock"
          if ! /bin/mkdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null; then
            cmux_ssh_auth_reclaim_stale_reaper_lock "$cmux_ssh_auth_reaper_lock" || return 0
            /bin/mkdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || return 0
          fi
          cmux_ssh_auth_reaper_publisher_identity=$(cmux_ssh_auth_identity "$$")
          if [ -z "$cmux_ssh_auth_reaper_publisher_identity" ] || ! \
            printf '%s|%s\n' "$$" "$cmux_ssh_auth_reaper_publisher_identity" \
              > "$cmux_ssh_auth_reaper_lock/publisher.new" 2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_reaper_lock/publisher.new" \
              "$cmux_ssh_auth_reaper_lock/publisher" 2>/dev/null; then
            /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/publisher.new" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || true
            return 0
          fi
          printf 'cleanup-pending\n' \
            > "$cmux_ssh_auth_reaper_group_dir/reaper.failed.new" 2>/dev/null || {
              /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/publisher" 2>/dev/null || true
              /bin/rmdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || true
              return 0
            }
          /bin/mv -f -- "$cmux_ssh_auth_reaper_group_dir/reaper.failed.new" \
            "$cmux_ssh_auth_reaper_group_dir/reaper.failed" 2>/dev/null || {
              /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/publisher" 2>/dev/null || true
              /bin/rmdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || true
              return 0
            }
          (
            trap '' HUP INT TERM
            CMUX_SSH_AUTH_GROUP_DIR="$cmux_ssh_auth_reaper_group_dir"
            export CMUX_SSH_AUTH_GROUP_DIR
            cmux_ssh_auth_reaper_owner_attempt=0
            while [ ! -s "$cmux_ssh_auth_reaper_lock/owner" ] && \
              [ "$cmux_ssh_auth_reaper_owner_attempt" -lt 100 ]; do
              /bin/sleep 0.01
              cmux_ssh_auth_reaper_owner_attempt=$((cmux_ssh_auth_reaper_owner_attempt + 1))
            done
            if [ ! -s "$cmux_ssh_auth_reaper_lock/owner" ]; then
              /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/publisher" \
                "$cmux_ssh_auth_reaper_lock/publisher.new" 2>/dev/null || true
              /bin/rmdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || true
              exit 0
            fi
            cmux_ssh_auth_reaper_attempt=0
            cmux_ssh_auth_reaper_delay=1
            while [ -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ] && \
              [ "$cmux_ssh_auth_reaper_attempt" -lt 3 ]; do
              cmux_ssh_auth_reaper_attempt=$((cmux_ssh_auth_reaper_attempt + 1))
              cmux_ssh_terminate_owned_auth_group "$cmux_ssh_auth_reaper_caller_group"
              if [ ! -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; then break; fi
              if [ "$cmux_ssh_auth_reaper_attempt" -lt 3 ]; then
                /bin/sleep "$cmux_ssh_auth_reaper_delay"
                cmux_ssh_auth_reaper_delay=$((cmux_ssh_auth_reaper_delay * 2))
              fi
            done
            if [ -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; then
              printf 'cleanup-incomplete attempts=%s\n' "$cmux_ssh_auth_reaper_attempt" \
                > "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed.new" 2>/dev/null || true
              /bin/mv -f -- "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed.new" \
                "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed" 2>/dev/null || true
              /usr/bin/logger -t cmux \
                "SSH authentication cleanup deferred: $CMUX_SSH_AUTH_GROUP_DIR" \
                >/dev/null 2>&1 || true
            else
              /bin/rm -f -- "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed" \
                "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed.new" 2>/dev/null || true
            fi
            /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/owner" \
              "$cmux_ssh_auth_reaper_lock/owner.new" \
              "$cmux_ssh_auth_reaper_lock/publisher" \
              "$cmux_ssh_auth_reaper_lock/publisher.new" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || true
            if [ ! -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; then
              \#(groupStateFileRemovalShellCommand(includingCancellationMarker: true))
              /bin/rmdir "$CMUX_SSH_AUTH_GROUP_DIR" 2>/dev/null || true
            fi
          ) </dev/null >/dev/null 2>&1 &
          cmux_ssh_auth_reaper_pid=$!
          cmux_ssh_auth_reaper_identity=$(cmux_ssh_auth_identity "$cmux_ssh_auth_reaper_pid")
          if [ -z "$cmux_ssh_auth_reaper_identity" ] || ! \
            printf '%s|%s\n' "$cmux_ssh_auth_reaper_pid" "$cmux_ssh_auth_reaper_identity" \
              > "$cmux_ssh_auth_reaper_lock/owner.new" 2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_reaper_lock/owner.new" \
              "$cmux_ssh_auth_reaper_lock/owner" 2>/dev/null; then
            /bin/kill -KILL "$cmux_ssh_auth_reaper_pid" >/dev/null 2>&1 || true
            wait "$cmux_ssh_auth_reaper_pid" 2>/dev/null || true
            /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/owner.new" \
              "$cmux_ssh_auth_reaper_lock/publisher" \
              "$cmux_ssh_auth_reaper_lock/publisher.new" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || true
            return 0
          fi
          /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/publisher" \
            "$cmux_ssh_auth_reaper_lock/publisher.new" 2>/dev/null || true
          CMUX_SSH_AUTH_REAPER_LAUNCHED=1
          return 0
        }

        cmux_ssh_auth_recovery_prepare() {
          cmux_ssh_auth_recovery_base="${TMPDIR:-/tmp}"
          cmux_ssh_auth_recovery_root="$cmux_ssh_auth_recovery_base/cmux-ssh-auth-recovery"
          if [ -L "$cmux_ssh_auth_recovery_root" ]; then return 1; fi
          if [ ! -d "$cmux_ssh_auth_recovery_root" ]; then
            (umask 077; /bin/mkdir "$cmux_ssh_auth_recovery_root") 2>/dev/null || \
              [ -d "$cmux_ssh_auth_recovery_root" ] || return 1
          fi
          if [ -L "$cmux_ssh_auth_recovery_root" ]; then return 1; fi
          cmux_ssh_auth_recovery_expected_root_identity="$(/usr/bin/id -u):700"
          cmux_ssh_auth_recovery_observed_root_identity=$(/usr/bin/stat -f '%u:%Lp' \
            "$cmux_ssh_auth_recovery_root" 2>/dev/null || true)
          [ "$cmux_ssh_auth_recovery_observed_root_identity" = \
            "$cmux_ssh_auth_recovery_expected_root_identity" ]
        }

        cmux_ssh_auth_recovery_group_path_is_valid() {
          cmux_ssh_auth_recovery_candidate="$1"
          case "$cmux_ssh_auth_recovery_candidate" in
            "$cmux_ssh_auth_recovery_base"/cmux-ssh-auth-group.*)
              cmux_ssh_auth_recovery_suffix=${cmux_ssh_auth_recovery_candidate##*/cmux-ssh-auth-group.}
              case "$cmux_ssh_auth_recovery_suffix" in
                ''|*[!A-Za-z0-9._-]*) return 1 ;;
              esac
              ;;
            *) return 1 ;;
          esac
          return 0
        }

        cmux_ssh_auth_recovery_lock() {
          cmux_ssh_auth_recovery_prepare || return 1
          exec 9>> "$cmux_ssh_auth_recovery_root/lock" || return 1
          if ! /usr/bin/lockf -s -t 1 9; then
            exec 9>&-
            return 1
          fi
        }

        cmux_ssh_auth_recovery_unlock() {
          exec 9>&-
        }

        cmux_ssh_auth_recovery_read_index() {
          cmux_ssh_auth_recovery_index=$(/bin/cat -- "$1" 2>/dev/null || true)
          case "$cmux_ssh_auth_recovery_index" in
            ''|*[!0-9]*) printf '0\n' ;;
            *)
              if [ "${#cmux_ssh_auth_recovery_index}" -gt 12 ]; then
                printf '0\n'
              else
                printf '%s\n' "$cmux_ssh_auth_recovery_index"
              fi
              ;;
          esac
        }

        cmux_ssh_auth_recovery_write_index_locked() {
          cmux_ssh_auth_recovery_index_file="$1"
          cmux_ssh_auth_recovery_index_value="$2"
          printf '%s\n' "$cmux_ssh_auth_recovery_index_value" \
            > "$cmux_ssh_auth_recovery_index_file.new" 2>/dev/null && \
            /bin/mv -f -- "$cmux_ssh_auth_recovery_index_file.new" \
              "$cmux_ssh_auth_recovery_index_file" 2>/dev/null
        }

        cmux_ssh_auth_recovery_append_locked() {
          cmux_ssh_auth_recovery_append_group="$1"
          cmux_ssh_auth_recovery_group_path_is_valid \
            "$cmux_ssh_auth_recovery_append_group" || return 1
          cmux_ssh_auth_recovery_write_index=$(cmux_ssh_auth_recovery_read_index \
            "$cmux_ssh_auth_recovery_root/write.index")
          cmux_ssh_auth_recovery_write_segment="$cmux_ssh_auth_recovery_root/queue.$cmux_ssh_auth_recovery_write_index"
          if [ -L "$cmux_ssh_auth_recovery_write_segment" ]; then return 1; fi
          cmux_ssh_auth_recovery_segment_count=0
          if [ -f "$cmux_ssh_auth_recovery_write_segment" ]; then
            cmux_ssh_auth_recovery_segment_count=$(/usr/bin/awk '
              NR == 8 { print 8; cmux_printed = 1; exit }
              END { if (!cmux_printed) print NR + 0 }
            ' "$cmux_ssh_auth_recovery_write_segment" 2>/dev/null || printf '64\n')
          fi
          case "$cmux_ssh_auth_recovery_segment_count" in
            ''|*[!0-9]*) return 1 ;;
          esac
          if [ "$cmux_ssh_auth_recovery_segment_count" -ge 8 ]; then
            cmux_ssh_auth_recovery_write_index=$((cmux_ssh_auth_recovery_write_index + 1))
            cmux_ssh_auth_recovery_write_segment="$cmux_ssh_auth_recovery_root/queue.$cmux_ssh_auth_recovery_write_index"
            if [ -L "$cmux_ssh_auth_recovery_write_segment" ]; then return 1; fi
          fi
          cmux_ssh_auth_recovery_write_index_locked \
            "$cmux_ssh_auth_recovery_root/write.index" \
            "$cmux_ssh_auth_recovery_write_index" || return 1
          printf '%s\n' "$cmux_ssh_auth_recovery_append_group" \
            >> "$cmux_ssh_auth_recovery_write_segment" 2>/dev/null
        }

        cmux_ssh_auth_recovery_enqueue() {
          cmux_ssh_auth_recovery_prepare || return 1
          cmux_ssh_auth_recovery_group_path_is_valid "$1" || return 1
          cmux_ssh_auth_recovery_lock || return 1
          cmux_ssh_auth_recovery_append_locked "$1"
          cmux_ssh_auth_recovery_enqueue_status=$?
          cmux_ssh_auth_recovery_unlock
          return "$cmux_ssh_auth_recovery_enqueue_status"
        }

        cmux_ssh_auth_create_group_dir() {
          cmux_ssh_auth_recovery_prepare || return 1
          cmux_ssh_auth_create_uuid=$(/usr/bin/uuidgen 2>/dev/null | \
            /usr/bin/tr '[:upper:]' '[:lower:]') || return 1
          case "$cmux_ssh_auth_create_uuid" in
            ''|*[!a-z0-9-]*) return 1 ;;
          esac
          cmux_ssh_auth_create_dir="$cmux_ssh_auth_recovery_base/cmux-ssh-auth-group.$cmux_ssh_auth_create_uuid"
          cmux_ssh_auth_recovery_group_path_is_valid "$cmux_ssh_auth_create_dir" || return 1
          cmux_ssh_auth_recovery_lock || return 1
          if ! cmux_ssh_auth_recovery_append_locked "$cmux_ssh_auth_create_dir" || \
            ! (umask 077; /bin/mkdir "$cmux_ssh_auth_create_dir") 2>/dev/null; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          cmux_ssh_auth_create_now=$(/bin/date +%s 2>/dev/null || true)
          case "$cmux_ssh_auth_create_now" in
            ''|*[!0-9]*)
              /bin/rmdir "$cmux_ssh_auth_create_dir" 2>/dev/null || true
              cmux_ssh_auth_recovery_unlock
              return 1
              ;;
          esac
          if ! printf '%s\n' "$cmux_ssh_auth_create_now" \
            > "$cmux_ssh_auth_create_dir/created.new" 2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_create_dir/created.new" \
              "$cmux_ssh_auth_create_dir/created" 2>/dev/null; then
            /bin/rm -f -- "$cmux_ssh_auth_create_dir/created.new" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_create_dir" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          cmux_ssh_auth_recovery_unlock
          printf '%s\n' "$cmux_ssh_auth_create_dir"
        }

        cmux_ssh_auth_recovery_claim_segment() {
          CMUX_SSH_AUTH_RECOVERY_SEGMENT=
          CMUX_SSH_AUTH_RECOVERY_SEGMENT_INDEX=
          CMUX_SSH_AUTH_RECOVERY_CLAIM_RECORD=
          cmux_ssh_auth_recovery_lock || return 1
          cmux_ssh_auth_recovery_read_index_value=$(cmux_ssh_auth_recovery_read_index \
            "$cmux_ssh_auth_recovery_root/read.index")
          cmux_ssh_auth_recovery_write_index_value=$(cmux_ssh_auth_recovery_read_index \
            "$cmux_ssh_auth_recovery_root/write.index")
          if [ "$cmux_ssh_auth_recovery_read_index_value" -gt \
            "$cmux_ssh_auth_recovery_write_index_value" ]; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          cmux_ssh_auth_recovery_segment="$cmux_ssh_auth_recovery_root/queue.$cmux_ssh_auth_recovery_read_index_value"
          if [ "$cmux_ssh_auth_recovery_read_index_value" = \
            "$cmux_ssh_auth_recovery_write_index_value" ]; then
            if [ ! -s "$cmux_ssh_auth_recovery_segment" ]; then
              cmux_ssh_auth_recovery_unlock
              return 1
            fi
            cmux_ssh_auth_recovery_next_write=$((cmux_ssh_auth_recovery_write_index_value + 1))
            if ! cmux_ssh_auth_recovery_write_index_locked \
              "$cmux_ssh_auth_recovery_root/write.index" \
              "$cmux_ssh_auth_recovery_next_write"; then
              cmux_ssh_auth_recovery_unlock
              return 1
            fi
          elif [ ! -s "$cmux_ssh_auth_recovery_segment" ]; then
            /bin/rm -f -- "$cmux_ssh_auth_recovery_segment" \
              "$cmux_ssh_auth_recovery_segment.claim" \
              "$cmux_ssh_auth_recovery_segment.claim.new" \
              "$cmux_ssh_auth_recovery_segment.priority" \
              "$cmux_ssh_auth_recovery_segment.retry" 2>/dev/null || true
            cmux_ssh_auth_recovery_next_read=$((cmux_ssh_auth_recovery_read_index_value + 1))
            cmux_ssh_auth_recovery_write_index_locked \
              "$cmux_ssh_auth_recovery_root/read.index" \
              "$cmux_ssh_auth_recovery_next_read" || true
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          if [ -L "$cmux_ssh_auth_recovery_segment" ]; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          cmux_ssh_auth_recovery_claim="$cmux_ssh_auth_recovery_segment.claim"
          if cmux_ssh_auth_recorded_process_is_live "$cmux_ssh_auth_recovery_claim"; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          /bin/rm -f -- "$cmux_ssh_auth_recovery_claim" \
            "$cmux_ssh_auth_recovery_claim.new" 2>/dev/null || true
          cmux_ssh_auth_recovery_claim_identity=$(cmux_ssh_auth_identity "$$")
          if [ -z "$cmux_ssh_auth_recovery_claim_identity" ]; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          cmux_ssh_auth_recovery_claim_record="$$|$cmux_ssh_auth_recovery_claim_identity"
          if ! printf '%s\n' "$cmux_ssh_auth_recovery_claim_record" \
            > "$cmux_ssh_auth_recovery_claim.new" 2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_recovery_claim.new" \
              "$cmux_ssh_auth_recovery_claim" 2>/dev/null; then
            /bin/rm -f -- "$cmux_ssh_auth_recovery_claim.new" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          CMUX_SSH_AUTH_RECOVERY_SEGMENT="$cmux_ssh_auth_recovery_segment"
          CMUX_SSH_AUTH_RECOVERY_SEGMENT_INDEX="$cmux_ssh_auth_recovery_read_index_value"
          CMUX_SSH_AUTH_RECOVERY_CLAIM_RECORD="$cmux_ssh_auth_recovery_claim_record"
          cmux_ssh_auth_recovery_unlock
          return 0
        }

        cmux_ssh_auth_recovery_complete_segment() {
          cmux_ssh_auth_recovery_lock || return 1
          cmux_ssh_auth_recovery_current_read=$(cmux_ssh_auth_recovery_read_index \
            "$cmux_ssh_auth_recovery_root/read.index")
          cmux_ssh_auth_recovery_observed_claim=$(/bin/cat -- \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.claim" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_recovery_current_read" != \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT_INDEX" ] || \
            [ "$cmux_ssh_auth_recovery_observed_claim" != \
              "$CMUX_SSH_AUTH_RECOVERY_CLAIM_RECORD" ]; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          for cmux_ssh_auth_recovery_requeue_file in \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.priority" \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"; do
            cmux_ssh_auth_recovery_requeue_count=0
            while IFS= read -r cmux_ssh_auth_recovery_requeue_group; do
              cmux_ssh_auth_recovery_requeue_count=$((cmux_ssh_auth_recovery_requeue_count + 1))
              if [ "$cmux_ssh_auth_recovery_requeue_count" -gt 8 ]; then
                cmux_ssh_auth_recovery_unlock
                return 1
              fi
              cmux_ssh_auth_recovery_append_locked \
                "$cmux_ssh_auth_recovery_requeue_group" || {
                  cmux_ssh_auth_recovery_unlock
                  return 1
                }
            done < "$cmux_ssh_auth_recovery_requeue_file"
          done
          /bin/rm -f -- "$CMUX_SSH_AUTH_RECOVERY_SEGMENT" \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.claim" \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.claim.new" \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.priority" \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry" 2>/dev/null || true
          cmux_ssh_auth_recovery_next_read=$((CMUX_SSH_AUTH_RECOVERY_SEGMENT_INDEX + 1))
          if ! cmux_ssh_auth_recovery_write_index_locked \
            "$cmux_ssh_auth_recovery_root/read.index" \
            "$cmux_ssh_auth_recovery_next_read"; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          cmux_ssh_auth_recovery_unlock
          return 0
        }

        cmux_ssh_resume_failed_auth_group_reapers() {
          cmux_ssh_auth_recovery_claim_segment || return 0
          : > "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.priority" 2>/dev/null || return 0
          : > "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry" 2>/dev/null || return 0
          cmux_ssh_auth_recovery_count=0
          cmux_ssh_auth_recovery_processed=0
          cmux_ssh_auth_recovery_expected_dir_identity="$(/usr/bin/id -u):700"
          while IFS= read -r cmux_ssh_auth_recovery_group_dir; do
            cmux_ssh_auth_recovery_processed=$((cmux_ssh_auth_recovery_processed + 1))
            if [ "$cmux_ssh_auth_recovery_processed" -gt 8 ]; then break; fi
            if ! cmux_ssh_auth_recovery_group_path_is_valid \
              "$cmux_ssh_auth_recovery_group_dir" || \
              [ ! -d "$cmux_ssh_auth_recovery_group_dir" ] || \
              [ -L "$cmux_ssh_auth_recovery_group_dir" ]; then continue; fi
            cmux_ssh_auth_recovery_observed_dir_identity=$(/usr/bin/stat -f '%u:%Lp' \
              "$cmux_ssh_auth_recovery_group_dir" 2>/dev/null || true)
            if [ "$cmux_ssh_auth_recovery_observed_dir_identity" != \
              "$cmux_ssh_auth_recovery_expected_dir_identity" ]; then continue; fi
            if [ "$cmux_ssh_auth_recovery_group_dir" = \
              "${CMUX_SSH_AUTH_GROUP_DIR:-}" ]; then
              printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
                >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"
              continue
            fi
            if [ ! -s "$cmux_ssh_auth_recovery_group_dir/identity" ]; then
              if cmux_ssh_auth_group_creation_retention_expired \
                "$cmux_ssh_auth_recovery_group_dir"; then
                (CMUX_SSH_AUTH_GROUP_DIR="$cmux_ssh_auth_recovery_group_dir"
                  \#(processGroupStateRemovalShellCommand())
                  /bin/rmdir "$CMUX_SSH_AUTH_GROUP_DIR" 2>/dev/null || true)
              else
                printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
                  >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"
              fi
              continue
            fi
            if cmux_ssh_auth_group_publisher_is_live \
              "$cmux_ssh_auth_recovery_group_dir"; then
              /bin/rm -f -- "$cmux_ssh_auth_recovery_group_dir/orphaned" \
                "$cmux_ssh_auth_recovery_group_dir/orphaned.new" 2>/dev/null || true
              printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
                >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"
              continue
            fi
            if cmux_ssh_auth_group_anchor_is_live \
              "$cmux_ssh_auth_recovery_group_dir"; then
              /bin/rm -f -- "$cmux_ssh_auth_recovery_group_dir/orphaned" \
                "$cmux_ssh_auth_recovery_group_dir/orphaned.new" 2>/dev/null || true
            elif cmux_ssh_auth_group_orphan_retention_expired \
              "$cmux_ssh_auth_recovery_group_dir"; then
              (CMUX_SSH_AUTH_GROUP_DIR="$cmux_ssh_auth_recovery_group_dir"
                \#(processGroupStateRemovalShellCommand())
                /bin/rmdir "$CMUX_SSH_AUTH_GROUP_DIR" 2>/dev/null || true)
              continue
            fi
            if [ "$cmux_ssh_auth_recovery_count" -ge 8 ]; then
              printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
                >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.priority"
              continue
            fi
            cmux_ssh_launch_owned_auth_group_reaper "$cmux_ssh_auth_recovery_group_dir"
            if [ "${CMUX_SSH_AUTH_REAPER_LAUNCHED:-0}" = 1 ]; then
              cmux_ssh_auth_recovery_count=$((cmux_ssh_auth_recovery_count + 1))
            fi
            printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
              >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"
          done < "$CMUX_SSH_AUTH_RECOVERY_SEGMENT"
          cmux_ssh_auth_recovery_complete_segment || true
          return 0
        }

        cmux_ssh_terminate_owned_auth_group() (
          cmux_ssh_auth_group_dir="${CMUX_SSH_AUTH_GROUP_DIR:-}"
          if [ -z "$cmux_ssh_auth_group_dir" ]; then exit 0; fi
          cmux_ssh_auth_expected_dir_identity="$(/usr/bin/id -u):700"
          cmux_ssh_auth_observed_dir_identity=$(/usr/bin/stat -f '%u:%Lp' "$cmux_ssh_auth_group_dir" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_observed_dir_identity" != "$cmux_ssh_auth_expected_dir_identity" ]; then exit 0; fi
          cmux_ssh_auth_group_file="$cmux_ssh_auth_group_dir/identity"
          cmux_ssh_auth_group_cancel_file="$cmux_ssh_auth_group_dir/cancel"
          cmux_ssh_auth_process_snapshot="$cmux_ssh_auth_group_dir/processes"
          cmux_ssh_auth_poststop_snapshot="$cmux_ssh_auth_group_dir/processes.stopped"
          cmux_ssh_auth_owned_processes="$cmux_ssh_auth_group_dir/owned"
          cmux_ssh_auth_next_owned_processes="$cmux_ssh_auth_group_dir/owned.next"
          cmux_ssh_auth_owned_groups="$cmux_ssh_auth_group_dir/groups"
          cmux_ssh_auth_next_owned_groups="$cmux_ssh_auth_group_dir/groups.next"
          cmux_ssh_auth_resume_groups="$cmux_ssh_auth_group_dir/groups.resume"
          cmux_ssh_auth_frozen_processes="$cmux_ssh_auth_group_dir/frozen"
          cmux_ssh_auth_individual_processes="$cmux_ssh_auth_group_dir/individuals"
          cmux_ssh_auth_ordered_processes="$cmux_ssh_auth_group_dir/ordered"
          cmux_ssh_auth_signaled_groups="$cmux_ssh_auth_group_dir/signaled.groups"
          cmux_ssh_auth_signaled_processes="$cmux_ssh_auth_group_dir/signaled.pids"
          cmux_ssh_auth_remove_cancel=0
          cmux_ssh_auth_cleanup_started=0
          cmux_ssh_auth_cleanup_complete=0
          cmux_ssh_auth_preserve_group_state=0
          cmux_ssh_auth_group_state_cleanup() {
            if [ "$cmux_ssh_auth_cleanup_started" = 1 ] && \
              [ "$cmux_ssh_auth_cleanup_complete" != 1 ]; then
              if cmux_ssh_auth_deadline_allows_work && \
                cmux_ssh_auth_force_owned_processes >/dev/null 2>&1; then
                cmux_ssh_auth_cleanup_complete=1
              else
                cmux_ssh_auth_deadline_millis="$cmux_ssh_auth_hard_deadline_millis"
                if cmux_ssh_auth_take_process_snapshot "$cmux_ssh_auth_process_snapshot" \
                  >/dev/null 2>&1 && \
                  cmux_ssh_auth_expand_owned_processes >/dev/null 2>&1 && \
                  cmux_ssh_auth_freeze_owned_processes >/dev/null 2>&1 && \
                  cmux_ssh_auth_force_frozen_processes >/dev/null 2>&1; then
                  cmux_ssh_auth_cleanup_complete=1
                else
                  cmux_ssh_auth_preserve_group_state=1
                  cmux_ssh_auth_resume_signaled_processes
                fi
              fi
            fi
            if [ "$cmux_ssh_auth_cleanup_complete" = 1 ]; then
              cmux_ssh_auth_preserve_group_state=0
            fi
            if [ "$cmux_ssh_auth_preserve_group_state" = 1 ]; then return; fi
            \#(groupStateFileRemovalShellCommand(includingCancellationMarker: false))
            if [ "$cmux_ssh_auth_remove_cancel" = 1 ]; then
              /bin/rm -f -- "$cmux_ssh_auth_group_cancel_file" 2>/dev/null || true
            fi
            /bin/rmdir "$cmux_ssh_auth_group_dir" 2>/dev/null || true
          }
          trap 'cmux_ssh_auth_group_state_cleanup' EXIT
          if [ ! -d "$cmux_ssh_auth_group_dir" ]; then exit 0; fi
          : > "$cmux_ssh_auth_group_cancel_file" 2>/dev/null || exit 0

          cmux_ssh_auth_group_attempt=0
          while [ -d "$cmux_ssh_auth_group_dir" ] && [ ! -s "$cmux_ssh_auth_group_file" ] && \
            [ "$cmux_ssh_auth_group_attempt" -lt 200 ]; do
            /bin/sleep 0.01
            cmux_ssh_auth_group_attempt=$((cmux_ssh_auth_group_attempt + 1))
          done
          if [ ! -s "$cmux_ssh_auth_group_file" ]; then exit 0; fi
          cmux_ssh_auth_preserve_group_state=1

          cmux_ssh_auth_group_identity=$(/bin/cat -- "$cmux_ssh_auth_group_file" 2>/dev/null || true)
          cmux_ssh_auth_group_anchor=${cmux_ssh_auth_group_identity%%|*}
          cmux_ssh_auth_group_remainder=${cmux_ssh_auth_group_identity#*|}
          cmux_ssh_auth_owned_group=${cmux_ssh_auth_group_remainder%%|*}
          cmux_ssh_auth_anchor_started=${cmux_ssh_auth_group_remainder#*|}
          case "$cmux_ssh_auth_group_anchor:$cmux_ssh_auth_owned_group:$cmux_ssh_auth_anchor_started" in
            *[!A-Za-z0-9_:]*|:*|*:) exit 0 ;;
          esac

          cmux_ssh_auth_caller_group="${1:-}"
          if [ -z "$cmux_ssh_auth_caller_group" ]; then
            cmux_ssh_auth_caller_group=$(/usr/bin/env LC_ALL=C LANG=C \
              /bin/ps -o pgid= -p "$$" 2>/dev/null | /usr/bin/tr -d '[:space:]')
          fi
          case "$cmux_ssh_auth_caller_group" in ''|*[!0-9]*) exit 0 ;; esac
          if [ "$cmux_ssh_auth_owned_group" = "$cmux_ssh_auth_caller_group" ]; then exit 0; fi

          cmux_ssh_auth_anchor_identity=$(cmux_ssh_auth_identity "$cmux_ssh_auth_group_anchor")
          cmux_ssh_auth_anchor_remainder=${cmux_ssh_auth_anchor_identity#*|}
          cmux_ssh_auth_observed_group=${cmux_ssh_auth_anchor_remainder%%|*}
          cmux_ssh_auth_observed_started=${cmux_ssh_auth_anchor_remainder#*|}
          if [ "$cmux_ssh_auth_observed_group" != "$cmux_ssh_auth_owned_group" ] || \
            [ "$cmux_ssh_auth_observed_started" != "$cmux_ssh_auth_anchor_started" ]; then
            exit 0
          fi

          cmux_ssh_auth_remove_cancel=1
          : > "$cmux_ssh_auth_owned_processes" || exit 0
          : > "$cmux_ssh_auth_frozen_processes" || exit 0
          : > "$cmux_ssh_auth_signaled_groups" || exit 0
          : > "$cmux_ssh_auth_signaled_processes" || exit 0
          cmux_ssh_auth_cleanup_started_millis="$(cmux_ssh_auth_now_millis)" || exit 0
          case "$cmux_ssh_auth_cleanup_started_millis" in ''|*[!0-9]*) exit 0 ;; esac
          cmux_ssh_auth_deadline_millis=$((cmux_ssh_auth_cleanup_started_millis + 500))
          cmux_ssh_auth_hard_deadline_millis=$((cmux_ssh_auth_cleanup_started_millis + 2000))
          cmux_ssh_auth_cleanup_started=1
          cmux_ssh_auth_freeze_attempt=0
          while [ "$cmux_ssh_auth_freeze_attempt" -lt 4 ]; do
            cmux_ssh_auth_deadline_allows_work || exit 0
            cmux_ssh_auth_take_process_snapshot "$cmux_ssh_auth_process_snapshot" || exit 0
            cmux_ssh_auth_expand_owned_processes || exit 0
            cmux_ssh_auth_freeze_owned_processes || exit 0
            cmux_ssh_auth_freeze_attempt=$((cmux_ssh_auth_freeze_attempt + 1))
          done
          cmux_ssh_auth_force_owned_processes || exit 0
          cmux_ssh_auth_cleanup_complete=1
        )

        cmux_ssh_terminate_auth_process_tree() (
          cmux_ssh_auth_root_pid="$1"
          cmux_ssh_auth_root_parent="$2"
          cmux_ssh_auth_root_identity=
          case "$cmux_ssh_auth_root_pid:$cmux_ssh_auth_root_parent" in
            *[!0-9:]*|:*|*:) ;;
            *)
              cmux_ssh_auth_candidate_identity=$(cmux_ssh_auth_identity "$cmux_ssh_auth_root_pid")
              cmux_ssh_auth_observed_parent=${cmux_ssh_auth_candidate_identity%%|*}
              cmux_ssh_auth_root_remainder=${cmux_ssh_auth_candidate_identity#*|}
              cmux_ssh_auth_root_group=${cmux_ssh_auth_root_remainder%%|*}
              cmux_ssh_auth_root_started=${cmux_ssh_auth_root_remainder#*|}
              case "$cmux_ssh_auth_root_group:$cmux_ssh_auth_root_started" in
                *[!A-Za-z0-9_:]*|:*|*:) ;;
                *)
                  if [ "$cmux_ssh_auth_observed_parent" = "$cmux_ssh_auth_root_parent" ]; then
                    cmux_ssh_auth_root_identity="$cmux_ssh_auth_candidate_identity"
                  fi
                  ;;
              esac
              ;;
          esac

          cmux_ssh_terminate_owned_auth_group
          if [ -z "$cmux_ssh_auth_root_identity" ]; then exit 0; fi
          cmux_ssh_auth_current_root_identity=$(cmux_ssh_auth_identity "$cmux_ssh_auth_root_pid")
          if [ "$cmux_ssh_auth_current_root_identity" = "$cmux_ssh_auth_root_identity" ]; then
            kill -KILL "$cmux_ssh_auth_root_pid" >/dev/null 2>&1 || true
          fi
        )
        """#
    }

    /// Wraps a zsh command so status-255 failures become transient (254),
    /// unclassified (``unclassifiedFailureExitStatus``), or permanent (255).
    /// Every other exit status is preserved.
    ///
    /// The command runs under `script` so its standard streams remain attached
    /// to a PTY. A private FIFO receives a duplicate transcript while `sysread`
    /// emits 4 KiB records to an incremental classifier with a 128-byte
    /// cross-record carry. The classifier retains only a bounded result marker.
    /// A parent read/write descriptor prevents either FIFO endpoint from
    /// deadlocking if `script` fails before opening the transcript. Apple
    /// `script` already propagates the child status; its newer compatibility-only
    /// `-e` flag is intentionally omitted for macOS 14.
    /// This keeps interactive prompts visible and terminal-aware without
    /// allowing a noisy remote command to grow memory or a diagnostic file.
    /// When the caller supplies an owned-group directory, completion hands its
    /// live identity to the enclosing retry wrapper for bounded final cleanup.
    ///
    /// The command must contain only the foreground authentication attempt and
    /// its required preflight, lock, and cleanup work. Callers execute unrelated
    /// local commands after this wrapper returns so their statuses are not
    /// interpreted as SSH authentication failures.
    ///
    /// - Parameter command: Foreground authentication command to execute under zsh.
    /// - Returns: A zsh command suitable for embedding in a startup script.
    public func classifyingTransientFailure(in command: String) -> String {
        let ownedGroupCommand = [
            "cmux_ssh_auth_group_dir=\"${CMUX_SSH_AUTH_GROUP_DIR:-}\"",
            "if [ -z \"$cmux_ssh_auth_group_dir\" ]; then exec /usr/bin/env LC_ALL=C LANG=C /bin/zsh -fc \(shellQuote(command)); fi",
            "cmux_ssh_auth_expected_dir_identity=\"$(/usr/bin/id -u):700\"",
            "cmux_ssh_auth_observed_dir_identity=$(/usr/bin/stat -f '%u:%Lp' \"$cmux_ssh_auth_group_dir\" 2>/dev/null || true)",
            "if [ \"$cmux_ssh_auth_observed_dir_identity\" != \"$cmux_ssh_auth_expected_dir_identity\" ]; then exit 255; fi",
            "cmux_ssh_auth_group_file=\"$cmux_ssh_auth_group_dir/identity\"",
            "cmux_ssh_auth_group_anchor_pid=",
            "cmux_ssh_auth_group_anchor_guard_fd=",
            "cmux_ssh_auth_group_anchor_fifo=\"$cmux_ssh_auth_group_dir/anchor\"",
            "cmux_ssh_auth_group_publish_file=\"$cmux_ssh_auth_group_dir/identity.new\"",
            "cmux_ssh_auth_group_publisher_file=\"$cmux_ssh_auth_group_dir/publisher\"",
            "cmux_ssh_auth_group_publisher_publish_file=\"$cmux_ssh_auth_group_dir/publisher.new\"",
            "cmux_ssh_auth_group_cancel_file=\"$cmux_ssh_auth_group_dir/cancel\"",
            "cmux_ssh_auth_group_published=0",
            "cmux_ssh_auth_group_cleanup() {",
            "  trap - EXIT HUP INT TERM",
            "  if [ \"$cmux_ssh_auth_group_published\" = 1 ]; then return; fi",
            "  if [ -n \"${cmux_ssh_auth_group_anchor_pid:-}\" ]; then",
            "    /bin/kill -KILL \"$cmux_ssh_auth_group_anchor_pid\" >/dev/null 2>&1 || true",
            "    wait \"$cmux_ssh_auth_group_anchor_pid\" 2>/dev/null || true",
            "  fi",
            "  if [ -n \"${cmux_ssh_auth_group_anchor_guard_fd:-}\" ]; then",
            "    exec {cmux_ssh_auth_group_anchor_guard_fd}>&-",
            "    cmux_ssh_auth_group_anchor_guard_fd=",
            "  fi",
            "  /bin/rm -f -- \"$cmux_ssh_auth_group_publish_file\" \"$cmux_ssh_auth_group_publisher_file\" \"$cmux_ssh_auth_group_publisher_publish_file\" \"$cmux_ssh_auth_group_anchor_fifo\" \"$cmux_ssh_auth_group_file\" \"$cmux_ssh_auth_group_cancel_file\" 2>/dev/null || true",
            "  /bin/rmdir \"$cmux_ssh_auth_group_dir\" 2>/dev/null || true",
            "}",
            "cmux_ssh_auth_group_handoff() {",
            "  trap - EXIT HUP INT TERM",
            "  if [ -n \"${cmux_ssh_auth_group_anchor_guard_fd:-}\" ]; then",
            "    exec {cmux_ssh_auth_group_anchor_guard_fd}>&-",
            "    cmux_ssh_auth_group_anchor_guard_fd=",
            "  fi",
            "  /bin/rm -f -- \"$cmux_ssh_auth_group_publish_file\" \"$cmux_ssh_auth_group_publisher_publish_file\" 2>/dev/null || true",
            "}",
            "cmux_ssh_auth_group_signal_exit() {",
            "  cmux_ssh_auth_group_signal_status=\"$1\"",
            "  /bin/rm -f -- \"$cmux_ssh_auth_group_publish_file\" \"$cmux_ssh_auth_group_publisher_publish_file\" 2>/dev/null || true",
            "  if [ \"$cmux_ssh_auth_group_published\" != 1 ]; then",
            "    cmux_ssh_auth_group_cleanup",
            "    exit \"$cmux_ssh_auth_group_signal_status\"",
            "  fi",
            "  trap - EXIT HUP INT TERM",
            "  exit \"$cmux_ssh_auth_group_signal_status\"",
            "}",
            "trap 'cmux_ssh_auth_group_cleanup' EXIT",
            "trap 'cmux_ssh_auth_group_signal_exit 129' HUP",
            "trap 'cmux_ssh_auth_group_signal_exit 130' INT",
            "trap 'cmux_ssh_auth_group_signal_exit 143' TERM",
            "if [ -e \"$cmux_ssh_auth_group_cancel_file\" ]; then exit 143; fi",
            "/usr/bin/mkfifo \"$cmux_ssh_auth_group_anchor_fifo\" || exit 255",
            "exec {cmux_ssh_auth_group_anchor_guard_fd}<> \"$cmux_ssh_auth_group_anchor_fifo\" || exit 255",
            "( trap '' HUP INT TERM; while IFS= read -r cmux_ssh_auth_group_anchor_input; do :; done ) < \"$cmux_ssh_auth_group_anchor_fifo\" >/dev/null 2>&1 &",
            "cmux_ssh_auth_group_anchor_pid=$!",
            "cmux_ssh_auth_supervisor_group=$(/usr/bin/env LC_ALL=C LANG=C /bin/ps -o pgid= -p \"$$\" 2>/dev/null | /usr/bin/tr -d '[:space:]')",
            "cmux_ssh_auth_anchor_identity=$(/usr/bin/env LC_ALL=C LANG=C /bin/ps -o pgid= -o state= -o lstart= -p \"$cmux_ssh_auth_group_anchor_pid\" 2>/dev/null | /usr/bin/awk 'NF >= 7 && $2 !~ /Z/ { print $1 \"|\" $3 \"_\" $4 \"_\" $5 \"_\" $6 \"_\" $7 }')",
            "cmux_ssh_auth_anchor_group=${cmux_ssh_auth_anchor_identity%%|*}",
            "cmux_ssh_auth_anchor_started=${cmux_ssh_auth_anchor_identity#*|}",
            "case \"$cmux_ssh_auth_supervisor_group:$cmux_ssh_auth_anchor_group:$cmux_ssh_auth_anchor_started\" in *[!A-Za-z0-9_:]*) exit 255 ;; esac",
            "if [ \"$cmux_ssh_auth_supervisor_group\" != \"$$\" ] || [ \"$cmux_ssh_auth_anchor_group\" != \"$cmux_ssh_auth_supervisor_group\" ]; then exit 255; fi",
            "if [ -e \"$cmux_ssh_auth_group_cancel_file\" ]; then exit 143; fi",
            "cmux_ssh_auth_group_publisher_identity=$(/usr/bin/env LC_ALL=C LANG=C /bin/ps -o ppid= -o pgid= -o state= -o lstart= -p \"$$\" 2>/dev/null | /usr/bin/awk 'NF >= 8 && $3 !~ /Z/ { print $1 \"|\" $2 \"|\" $4 \"_\" $5 \"_\" $6 \"_\" $7 \"_\" $8 }')",
            "cmux_ssh_auth_group_publisher_parent=${cmux_ssh_auth_group_publisher_identity%%|*}",
            "cmux_ssh_auth_group_publisher_remainder=${cmux_ssh_auth_group_publisher_identity#*|}",
            "cmux_ssh_auth_group_publisher_group=${cmux_ssh_auth_group_publisher_remainder%%|*}",
            "cmux_ssh_auth_group_publisher_started=${cmux_ssh_auth_group_publisher_remainder#*|}",
            "case \"$cmux_ssh_auth_group_publisher_parent\" in ''|*[!0-9]*) exit 255 ;; esac",
            "case \"$cmux_ssh_auth_group_publisher_group\" in ''|*[!0-9]*) exit 255 ;; esac",
            "case \"$cmux_ssh_auth_group_publisher_started\" in ''|*[!A-Za-z0-9_:]*) exit 255 ;; esac",
            "printf '%s|%s\\n' \"$$\" \"$cmux_ssh_auth_group_publisher_identity\" > \"$cmux_ssh_auth_group_publisher_publish_file\" || exit 255",
            "printf '%s|%s|%s\\n' \"$cmux_ssh_auth_group_anchor_pid\" \"$cmux_ssh_auth_anchor_group\" \"$cmux_ssh_auth_anchor_started\" > \"$cmux_ssh_auth_group_publish_file\" || exit 255",
            "/bin/mv -f -- \"$cmux_ssh_auth_group_publish_file\" \"$cmux_ssh_auth_group_file\" || exit 255",
            "/bin/mv -f -- \"$cmux_ssh_auth_group_publisher_publish_file\" \"$cmux_ssh_auth_group_publisher_file\" || exit 255",
            "cmux_ssh_auth_group_published=1",
            "if [ -e \"$cmux_ssh_auth_group_cancel_file\" ]; then exit 143; fi",
            "unset CMUX_SSH_AUTH_GROUP_DIR",
            "/usr/bin/env LC_ALL=C LANG=C /bin/zsh -fc \(shellQuote(command))",
            "cmux_ssh_auth_group_status=$?",
            "cmux_ssh_auth_group_handoff",
            "exit \"$cmux_ssh_auth_group_status\"",
        ].joined(separator: "\n")
        let nestedCommand = "/usr/bin/env LC_ALL=C LANG=C /bin/zsh -fc \(shellQuote(ownedGroupCommand))"
        let classifierProgram = """
        {
          cmux_ssh_auth_line = tolower(cmux_ssh_auth_overlap $0)
          cmux_ssh_auth_transient_line = cmux_ssh_auth_line
          gsub(/connection closed by unknown port 65535/, "", cmux_ssh_auth_transient_line)
          gsub(/connection to unknown port 65535: broken pipe/, "", cmux_ssh_auth_transient_line)
          if (cmux_ssh_auth_line ~ cmux_ssh_auth_permanent_pattern) {
            print "permanent" > cmux_ssh_auth_classification
            close(cmux_ssh_auth_classification)
            cmux_ssh_auth_saw_permanent = 1
          } else if (!cmux_ssh_auth_saw_permanent && cmux_ssh_auth_transient_line ~ cmux_ssh_auth_transient_pattern) {
            print "transient" > cmux_ssh_auth_classification
            close(cmux_ssh_auth_classification)
          }
          if (length(cmux_ssh_auth_line) > 128) {
            cmux_ssh_auth_overlap = substr(cmux_ssh_auth_line, length(cmux_ssh_auth_line) - 127)
          } else {
            cmux_ssh_auth_overlap = cmux_ssh_auth_line
          }
        }
        """
        let script = [
            "umask 077",
            "cmux_ssh_auth_capture_dir=$(/usr/bin/mktemp -d \"${TMPDIR:-/tmp}/cmux-ssh-auth.XXXXXX\") || exit 255",
            "cmux_ssh_auth_capture_state=\"$cmux_ssh_auth_capture_dir/classification\"",
            "cmux_ssh_auth_classifier_fifo=\"$cmux_ssh_auth_capture_dir/classifier.fifo\"",
            "cmux_ssh_auth_classifier_guard_fd=",
            "cmux_ssh_auth_classifier_pid=",
            "cmux_ssh_auth_command_pid=",
            "cmux_ssh_auth_capture_cleanup() {",
            "  if [ -n \"${cmux_ssh_auth_classifier_guard_fd:-}\" ]; then",
            "    exec {cmux_ssh_auth_classifier_guard_fd}>&-",
            "    cmux_ssh_auth_classifier_guard_fd=",
            "  fi",
            "  for cmux_ssh_auth_capture_pid in \"${cmux_ssh_auth_command_pid:-}\" \"${cmux_ssh_auth_classifier_pid:-}\"; do",
            "    if [ -n \"$cmux_ssh_auth_capture_pid\" ]; then",
            "      /bin/kill \"$cmux_ssh_auth_capture_pid\" >/dev/null 2>&1 || true",
            "      wait \"$cmux_ssh_auth_capture_pid\" 2>/dev/null || true",
            "    fi",
            "  done",
            "  /bin/rm -f -- \"$cmux_ssh_auth_classifier_fifo\" \"$cmux_ssh_auth_capture_state\" 2>/dev/null || true",
            "  /bin/rmdir \"$cmux_ssh_auth_capture_dir\" 2>/dev/null || true",
            "}",
            "cmux_ssh_auth_capture_signal_exit() {",
            "  cmux_ssh_auth_capture_signal_status=\"$1\"",
            "  cmux_ssh_auth_capture_signal_name=\"$2\"",
            "  trap - EXIT HUP INT TERM",
            "  if [ -n \"${cmux_ssh_auth_command_pid:-}\" ]; then",
            "    /bin/kill -\"$cmux_ssh_auth_capture_signal_name\" \"$cmux_ssh_auth_command_pid\" >/dev/null 2>&1 || true",
            "    wait \"$cmux_ssh_auth_command_pid\" 2>/dev/null || true",
            "    cmux_ssh_auth_command_pid=",
            "  fi",
            "  cmux_ssh_auth_capture_cleanup",
            "  exit \"$cmux_ssh_auth_capture_signal_status\"",
            "}",
            "trap 'cmux_ssh_auth_capture_cleanup' EXIT",
            "trap 'cmux_ssh_auth_capture_signal_exit 129 HUP' HUP",
            "trap 'cmux_ssh_auth_capture_signal_exit 130 INT' INT",
            "trap 'cmux_ssh_auth_capture_signal_exit 143 TERM' TERM",
            "if ! /usr/bin/mkfifo \"$cmux_ssh_auth_classifier_fifo\"; then exit 255; fi",
            "exec {cmux_ssh_auth_classifier_guard_fd}<> \"$cmux_ssh_auth_classifier_fifo\" || exit 255",
            "( exec {cmux_ssh_auth_classifier_guard_fd}>&-; zmodload zsh/system || exit 255; exec {cmux_ssh_auth_classifier_fd}< \"$cmux_ssh_auth_classifier_fifo\" || exit 255; while sysread -i \"$cmux_ssh_auth_classifier_fd\" -s 4096 cmux_ssh_auth_classifier_chunk; do print -r -- \"$cmux_ssh_auth_classifier_chunk\"; done; exec {cmux_ssh_auth_classifier_fd}<&- ) | ( exec {cmux_ssh_auth_classifier_guard_fd}>&-; LC_ALL=C /usr/bin/awk -v cmux_ssh_auth_classification=\"$cmux_ssh_auth_capture_state\" -v cmux_ssh_auth_transient_pattern=\(shellQuote(transientFailurePattern)) -v cmux_ssh_auth_permanent_pattern=\(shellQuote(permanentFailurePattern)) \(shellQuote(classifierProgram)) ) &",
            "cmux_ssh_auth_classifier_pid=$!",
            "( exec {cmux_ssh_auth_classifier_guard_fd}>&-; exec /usr/bin/script -q -F \"$cmux_ssh_auth_classifier_fifo\" \(nestedCommand) <&0 >&2 ) &",
            "cmux_ssh_auth_command_pid=$!",
            "wait \"$cmux_ssh_auth_command_pid\"",
            "cmux_ssh_auth_capture_status=$?",
            "cmux_ssh_auth_command_pid=",
            "exec {cmux_ssh_auth_classifier_guard_fd}>&-",
            "cmux_ssh_auth_classifier_guard_fd=",
            "wait \"$cmux_ssh_auth_classifier_pid\" 2>/dev/null || true",
            "cmux_ssh_auth_classifier_pid=",
            "if [ \"$cmux_ssh_auth_capture_status\" -eq 255 ]; then",
            "  case \"$(/bin/cat -- \"$cmux_ssh_auth_capture_state\" 2>/dev/null || true)\" in",
            "    transient) cmux_ssh_auth_capture_status=254 ;;",
            "    permanent) ;;",
            "    *) cmux_ssh_auth_capture_status=\(unclassifiedFailureExitStatus) ;;",
            "  esac",
            "fi",
            "trap - EXIT HUP INT TERM",
            "cmux_ssh_auth_capture_cleanup",
            "exit \"$cmux_ssh_auth_capture_status\"",
        ].joined(separator: "\n")
        return "/bin/zsh -fc \(shellQuote(script))"
    }

    private func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
