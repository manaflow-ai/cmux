internal import Foundation

// Remote-side relay provisioning script builders. Static because they
// compose pure script text from raw inputs independent of a session instance
// (the CmuxCore SSH-option-normalization precedent); the script text is
// wire/process behavior pinned by tests — do not alter.
extension RemoteSessionCoordinator {
    /// Proves that stale relay metadata belongs to this relay namespace.
    ///
    /// Persistent restores deliberately rotate relay credentials, so their
    /// durable daemon slot is the cross-launch ownership identity. Relays
    /// without a persistent slot remain scoped to their exact credentials.
    static func remoteRelayMetadataOwnershipProbeScript(
        relayPort: Int,
        relayID: String,
        relayToken: String,
        persistentDaemonSlot: String?
    ) -> String {
        let authPayload =
            "{\"relay_id\":\"\(relayID)\",\"relay_token\":\"\(relayToken)\"}"
        let normalizedSlot = normalizedPersistentDaemonSlotForRemoteCleanup(
            persistentDaemonSlot
        )
        guard persistentDaemonSlot == nil || normalizedSlot != nil else {
            return "exit 64"
        }
        let ownershipCheck: String
        if let normalizedSlot {
            ownershipCheck = """
            [ -r "$auth_file" ] || exit 64
            [ -r "$slot_file" ] || exit 64
            [ "$(tr -d '\\r\\n' < "$slot_file")" = \(normalizedSlot.shellSingleQuoted) ] || exit 64
            """
        } else {
            ownershipCheck = """
            [ "$(tr -d '\\r\\n' < "$auth_file")" = \(authPayload.shellSingleQuoted) ] || exit 64
            [ ! -e "$slot_file" ] || exit 64
            """
        }
        return """
        relay_directory="$HOME/.cmux/relay"
        auth_file="$relay_directory/\(relayPort).auth"
        slot_file="$relay_directory/\(relayPort).slot"
        \(ownershipCheck)
        """
    }

    /// Builds a direct persistent-slot shutdown script when no relay metadata exists.
    static func remotePersistentDaemonStopScript(
        daemonRemotePath: String,
        persistentDaemonSlot: String?
    ) -> String? {
        let trimmedRemotePath = daemonRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRemotePath.isEmpty,
              let persistentDaemonSlot = normalizedPersistentDaemonSlotForRemoteCleanup(persistentDaemonSlot) else {
            return nil
        }
        let daemonPathExpression = remoteDaemonPathShellExpression(trimmedRemotePath)
        return """
        daemon_path=\(daemonPathExpression)
        [ -x "$daemon_path" ] || exit 1
        "$daemon_path" serve --persistent-stop --slot \(persistentDaemonSlot.shellSingleQuoted)
        """
    }

    /// Script that stops the expected persistent daemon slot and removes its owned relay state.
    ///
    /// - Parameters:
    ///   - relayPort: The reverse-relay port whose metadata is being removed.
    ///   - persistentDaemonSlot: The slot expected in the relay metadata, or `nil` for a nonpersistent relay.
    /// - Returns: A fail-closed shell script that removes state only after ownership is verified.
    public static func remoteRelayMetadataCleanupScript(
        relayPort: Int,
        persistentDaemonSlot: String?
    ) -> String {
        let normalizedSlot = normalizedPersistentDaemonSlotForRemoteCleanup(persistentDaemonSlot)
        guard persistentDaemonSlot == nil || normalizedSlot != nil else { return "exit 64" }
        let ownershipCheck = remoteRelayOwnershipCheckScript(
            persistentDaemonSlot: normalizedSlot
        )
        let persistentStop: String
        if normalizedSlot != nil {
            persistentStop = """
            persistent_stop_succeeded=0
            if [ -r "$daemon_path_file" ]; then
              daemon_path="$(tr -d '\\r\\n' < "$daemon_path_file")"
              if [ -x "$daemon_path" ]; then
                if "$daemon_path" serve --persistent-stop --slot "$persistent_slot" >/dev/null 2>&1; then
                  persistent_stop_succeeded=1
                fi
              fi
            fi
            [ "$persistent_stop_succeeded" -eq 1 ] || exit 1
            """
        } else {
            persistentStop = ""
        }

        return """
        relay_socket='127.0.0.1:\(relayPort)'
        relay_directory="$HOME/.cmux/relay"
        daemon_path_file="$relay_directory/\(relayPort).daemon_path"
        slot_file="$relay_directory/\(relayPort).slot"
        \(ownershipCheck)
        \(persistentStop)
        socket_addr_file="$HOME/.cmux/socket_addr"
        if [ -r "$socket_addr_file" ] && [ "$(tr -d '\\r\\n' < "$socket_addr_file")" = "$relay_socket" ]; then
          rm -f "$socket_addr_file"
        fi
        rm -f "$relay_directory/\(relayPort).auth" "$daemon_path_file" "$slot_file" "$relay_directory/\(relayPort).tty"
        rm -rf "$relay_directory/\(relayPort).shell"
        """
    }

    /// Removes transport-scoped relay metadata while preserving the persistent
    /// daemon slot and shell state across reconnect and system-sleep churn.
    static func remoteRelayTransportMetadataCleanupScript(
        relayPort: Int,
        persistentDaemonSlot: String?
    ) -> String {
        let normalizedSlot = normalizedPersistentDaemonSlotForRemoteCleanup(persistentDaemonSlot)
        guard persistentDaemonSlot == nil || normalizedSlot != nil else { return "exit 64" }
        let ownershipCheck = remoteRelayOwnershipCheckScript(
            persistentDaemonSlot: normalizedSlot
        )
        return """
        relay_socket='127.0.0.1:\(relayPort)'
        relay_directory="$HOME/.cmux/relay"
        slot_file="$relay_directory/\(relayPort).slot"
        \(ownershipCheck)
        socket_addr_file="$HOME/.cmux/socket_addr"
        if [ -r "$socket_addr_file" ] && [ "$(tr -d '\\r\\n' < "$socket_addr_file")" = "$relay_socket" ]; then
          rm -f "$socket_addr_file"
        fi
        rm -f "$relay_directory/\(relayPort).auth" "$relay_directory/\(relayPort).tty"
        """
    }

    private static func remoteRelayOwnershipCheckScript(persistentDaemonSlot: String?) -> String {
        if let persistentDaemonSlot {
            return """
            [ -r "$slot_file" ] || exit 64
            persistent_slot="$(tr -d '\\r\\n' < "$slot_file")"
            [ "$persistent_slot" = \(persistentDaemonSlot.shellSingleQuoted) ] || exit 64
            """
        }
        return "[ ! -e \"$slot_file\" ] || exit 64"
    }

    static func normalizedPersistentDaemonSlotForRemoteCleanup(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              trimmed.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    static func remoteCLIWrapperScript() -> String {
        """
        #!/bin/sh
        set -eu

        daemon="$HOME/.cmux/bin/cmuxd-remote-current"
        socket_path="${CMUX_SOCKET_PATH:-}"
        if [ -z "$socket_path" ] && [ -r "$HOME/.cmux/socket_addr" ]; then
          socket_path="$(tr -d '\\r\\n' < "$HOME/.cmux/socket_addr")"
        fi

        if [ -n "$socket_path" ] && [ "${socket_path#/}" = "$socket_path" ] && [ "${socket_path#*:}" != "$socket_path" ]; then
          relay_port="${socket_path##*:}"
          relay_map="$HOME/.cmux/relay/${relay_port}.daemon_path"
          if [ -r "$relay_map" ]; then
            mapped_daemon="$(tr -d '\\r\\n' < "$relay_map")"
            if [ -n "$mapped_daemon" ] && [ -x "$mapped_daemon" ]; then
              daemon="$mapped_daemon"
            fi
          fi
        fi

        exec "$daemon" "$@"
        """
    }

    static func remoteCLIWrapperInstallScript(
        daemonRemotePath: String,
        codexWrapperScript: String? = nil
    ) -> String {
        let trimmedRemotePath = daemonRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let daemonPathExpression = remoteDaemonPathShellExpression(trimmedRemotePath)
        let codexWrapperInstall: String
        if let codexWrapperScript,
           !codexWrapperScript.components(separatedBy: .newlines).contains("CMUXREMOTE_CODEX_WRAPPER") {
            codexWrapperInstall = """
            codex_wrapper_tmp="$HOME/.cmux/bin/.codex-wrapper.tmp.$$"
            if ! cat > "$codex_wrapper_tmp" <<'CMUXREMOTE_CODEX_WRAPPER'
            \(codexWrapperScript)
            CMUXREMOTE_CODEX_WRAPPER
            then
              rm -f "$codex_wrapper_tmp"
              exit 1
            fi
            chmod 755 "$codex_wrapper_tmp" || { rm -f "$codex_wrapper_tmp"; exit 1; }
            mv -f "$codex_wrapper_tmp" "$HOME/.cmux/bin/cmux-codex-wrapper" || { rm -f "$codex_wrapper_tmp"; exit 1; }
            """
        } else {
            codexWrapperInstall = ""
        }
        return """
        mkdir -p "$HOME/.cmux/bin" "$HOME/.cmux/relay"
        ln -sf \(daemonPathExpression) "$HOME/.cmux/bin/cmuxd-remote-current"
        wrapper_tmp="$HOME/.cmux/bin/.cmux-wrapper.tmp.$$"
        cat > "$wrapper_tmp" <<'CMUXWRAPPER'
        \(remoteCLIWrapperScript())
        CMUXWRAPPER
        chmod 755 "$wrapper_tmp"
        mv -f "$wrapper_tmp" "$HOME/.cmux/bin/cmux"
        \(codexWrapperInstall)
        """
    }

    static func remoteRelayMetadataInstallScript(
        daemonRemotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String,
        persistentDaemonSlot: String? = nil,
        codexWrapperScript: String? = nil
    ) -> String {
        let trimmedRemotePath = daemonRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let daemonPathExpression = remoteDaemonPathShellExpression(trimmedRemotePath)
        let slotMetadataLine: String
        if let slot = normalizedPersistentDaemonSlotForRemoteCleanup(persistentDaemonSlot) {
            slotMetadataLine = "printf '%s' \(slot.shellSingleQuoted) > \"$HOME/.cmux/relay/\(relayPort).slot\"\nchmod 600 \"$HOME/.cmux/relay/\(relayPort).slot\""
        } else {
            slotMetadataLine = "rm -f \"$HOME/.cmux/relay/\(relayPort).slot\""
        }
        let authPayload = """
        {"relay_id":"\(relayID)","relay_token":"\(relayToken)"}
        """
        return """
        umask 077
        mkdir -p "$HOME/.cmux" "$HOME/.cmux/relay"
        chmod 700 "$HOME/.cmux/relay"
        \(remoteCLIWrapperInstallScript(
            daemonRemotePath: trimmedRemotePath,
            codexWrapperScript: codexWrapperScript
        ))
        printf '%s' \(daemonPathExpression) > "$HOME/.cmux/relay/\(relayPort).daemon_path"
        \(slotMetadataLine)
        cat > "$HOME/.cmux/relay/\(relayPort).auth" <<'CMUXRELAYAUTH'
        \(authPayload)
        CMUXRELAYAUTH
        chmod 600 "$HOME/.cmux/relay/\(relayPort).auth"
        printf '%s' '127.0.0.1:\(relayPort)' > "$HOME/.cmux/socket_addr"
        """
    }

    static func remoteDaemonPathShellExpression(_ remotePath: String) -> String {
        let trimmedRemotePath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRemotePath.hasPrefix("/") {
            return trimmedRemotePath.shellSingleQuoted
        }
        return "\"$HOME/\(trimmedRemotePath)\""
    }
}
