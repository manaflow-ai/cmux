import CmuxTerminal
import Foundation

extension Workspace {
    /// Starts one token-checked remote disconnect transaction per surface.
    @discardableResult
    func transitionRemoteTerminalToDisconnectedPlaceholder(
        surfaceId: UUID,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        guard pendingRemoteTerminalChildExitSurfaceIds.contains(surfaceId),
              var replacement = pendingRemoteDisconnectReplacementsBySurfaceId[surfaceId],
              let panel = terminalPanel(for: surfaceId) else {
            return false
        }
        if case .preparing = replacement.phase { return true }

        let token = UUID()
        let runtimeSurface = panel.surface
        let fallbackScrollback = restoredTerminalScrollbackByPanelId[surfaceId]
        replacement.phase = .preparing(token: token, runtimeSurface: runtimeSurface, task: nil)
        pendingRemoteDisconnectReplacementsBySurfaceId[surfaceId] = replacement

        let task = Task { @MainActor [weak self, weak runtimeSurface] in
            guard let self, let runtimeSurface else { return }
            await self.prepareRemoteDisconnectPlaceholder(
                surfaceId: surfaceId,
                token: token,
                runtimeSurface: runtimeSurface,
                target: replacement.target,
                reconnectCommand: replacement.reconnectCommand,
                fallbackScrollback: fallbackScrollback,
                temporaryDirectory: temporaryDirectory
            )
        }
        replacement.phase = .preparing(token: token, runtimeSurface: runtimeSurface, task: task)
        pendingRemoteDisconnectReplacementsBySurfaceId[surfaceId] = replacement
        return true
    }

    func waitForRemoteDisconnectTransition(surfaceId: UUID) async {
        guard let replacement = pendingRemoteDisconnectReplacementsBySurfaceId[surfaceId],
              case .preparing(_, _, let task) = replacement.phase else {
            return
        }
        await task?.value
    }

    private func prepareRemoteDisconnectPlaceholder(
        surfaceId: UUID,
        token: UUID,
        runtimeSurface: TerminalSurface,
        target: String,
        reconnectCommand: String?,
        fallbackScrollback: String?,
        temporaryDirectory: URL
    ) async {
        let capturedScrollback = await runtimeSurface.boundedScreenTailVT(
            maxRows: SessionPersistencePolicy.maxScrollbackLinesPerTerminal,
            maxBytes: SessionPersistencePolicy.maxScrollbackCharactersPerTerminal
        )
        guard isCurrentRemoteDisconnectPreparation(
            surfaceId: surfaceId,
            token: token,
            runtimeSurface: runtimeSurface
        ) else { return }

        let scrollback = if capturedScrollback?.contains(where: { !$0.isWhitespace }) == true {
            capturedScrollback
        } else {
            Self.plainTextRemoteDisconnectFallbackScrollback(fallbackScrollback)
        }
        guard let prepared = await remoteDisconnectPreparationService.prepare(
            target: target,
            reconnectCommand: reconnectCommand,
            scrollback: scrollback,
            temporaryDirectory: temporaryDirectory
        ) else {
            resetRemoteDisconnectPreparationIfCurrent(
                surfaceId: surfaceId,
                token: token,
                runtimeSurface: runtimeSurface
            )
            return
        }
        guard isCurrentRemoteDisconnectPreparation(
            surfaceId: surfaceId,
            token: token,
            runtimeSurface: runtimeSurface
        ) else {
            await remoteDisconnectPreparationService.discard(
                placeholderCommand: prepared.placeholderCommand,
                replayFileURL: prepared.replayFileURL
            )
            return
        }

        guard respawnTerminalSurface(
            panelId: surfaceId,
            command: prepared.placeholderCommand,
            workingDirectory: currentDirectory,
            waitAfterCommand: true,
            replayFileURL: prepared.replayFileURL
        ) != nil else {
            await remoteDisconnectPreparationService.discard(
                placeholderCommand: prepared.placeholderCommand,
                replayFileURL: prepared.replayFileURL
            )
            resetRemoteDisconnectPreparationIfCurrent(
                surfaceId: surfaceId,
                token: token,
                runtimeSurface: runtimeSurface
            )
            return
        }
        pendingRemoteDisconnectReplacementsBySurfaceId.removeValue(forKey: surfaceId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(surfaceId)
        remoteDisconnectPlaceholderPanelIds.insert(surfaceId)
        restoredTerminalScrollbackByPanelId[surfaceId] = scrollback
    }

    private func isCurrentRemoteDisconnectPreparation(
        surfaceId: UUID,
        token: UUID,
        runtimeSurface: TerminalSurface
    ) -> Bool {
        guard terminalPanel(for: surfaceId)?.surface === runtimeSurface,
              let replacement = pendingRemoteDisconnectReplacementsBySurfaceId[surfaceId],
              case .preparing(let currentToken, let currentRuntimeSurface, _) = replacement.phase else {
            return false
        }
        return currentToken == token && currentRuntimeSurface === runtimeSurface
    }

    private func resetRemoteDisconnectPreparationIfCurrent(
        surfaceId: UUID,
        token: UUID,
        runtimeSurface: TerminalSurface
    ) {
        guard var replacement = pendingRemoteDisconnectReplacementsBySurfaceId[surfaceId],
              case .preparing(let currentToken, let currentRuntimeSurface, _) = replacement.phase,
              currentToken == token,
              currentRuntimeSurface === runtimeSurface else {
            return
        }
        replacement.phase = .awaitingChildExit
        pendingRemoteDisconnectReplacementsBySurfaceId[surfaceId] = replacement
    }

    /// Replays persisted fallback only when truncation cannot leave terminal control state open.
    nonisolated static func plainTextRemoteDisconnectFallbackScrollback(_ scrollback: String?) -> String? {
        guard let bounded = SessionPersistencePolicy.truncatedScrollback(scrollback) else { return nil }
        let containsTerminalControl = bounded.unicodeScalars.contains { scalar in
            let value = scalar.value
            let allowedWhitespace = value == 0x09 || value == 0x0A || value == 0x0D
            return !allowedWhitespace && (value < 0x20 || (0x7F...0x9F).contains(value))
        }
        return containsTerminalControl ? nil : bounded
    }

    /// Writes a small shell wrapper that keeps a disconnected remote terminal visible.
    /// The returned path goes to `initialCommand`; failure returns `nil` without a shell fallback.
    nonisolated static func remoteDisconnectPlaceholderScript(
        target: String,
        reconnectCommand: String?,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        let scriptURL = temporaryDirectory.appendingPathComponent(
            "cmux-remote-disconnect-\(UUID().uuidString.lowercased()).sh"
        )
        // Base64 keeps targets and localized text out of shell syntax, even if they contain
        // substitutions, backticks, quotes, or escape sequences.
        let encodedTarget = Data(target.utf8).base64EncodedString()
        let endedLineFormat = String(
            localized: "remote.disconnectBanner.sessionEnded",
            defaultValue: "[cmux] remote session disconnected: %s"
        )
        let reconnectLine = String(
            localized: "remote.disconnectBanner.reconnectHint",
            defaultValue: "[cmux] Press Enter to reconnect. This terminal will stay disconnected until then."
        )
        let reconnectUnavailableLine = String(
            localized: "remote.disconnectBanner.reconnectUnavailableHint",
            defaultValue: "[cmux] Reconnect this workspace from the sidebar or by running the original cmux remote command again."
        )
        let encodedEndedFormat = Data(endedLineFormat.utf8).base64EncodedString()
        let encodedReconnectLine = Data(reconnectLine.utf8).base64EncodedString()
        let encodedReconnectUnavailableLine = Data(reconnectUnavailableLine.utf8).base64EncodedString()
        let encodedReconnectCommand = Data((reconnectCommand ?? "").utf8).base64EncodedString()
        let body = """
        #!/bin/sh
        cmux_disconnect_decode() {
          printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null
        }
        cmux_disconnect_target="$(cmux_disconnect_decode '\(encodedTarget)')"
        cmux_disconnect_ended_format="$(cmux_disconnect_decode '\(encodedEndedFormat)')"
        cmux_disconnect_reconnect_line="$(cmux_disconnect_decode '\(encodedReconnectLine)')"
        cmux_disconnect_reconnect_unavailable_line="$(cmux_disconnect_decode '\(encodedReconnectUnavailableLine)')"
        cmux_disconnect_reconnect_command="$(cmux_disconnect_decode '\(encodedReconnectCommand)')"
        cmux_disconnect_scrollback_file="${CMUX_RESTORE_SCROLLBACK_FILE:-}"
        if [ -n "$cmux_disconnect_scrollback_file" ]; then
          cmux_disconnect_scrollback_token="${cmux_disconnect_scrollback_file##*/}"
          cmux_disconnect_host="$(/bin/hostname)"
          unset CMUX_RESTORE_SCROLLBACK_FILE
          printf '\\033]1337;CurrentDir=kitty-shell-cwd://%s/.cmux/session-scrollback-replay/%s/start\\007' "$cmux_disconnect_host" "$cmux_disconnect_scrollback_token"
          if [ -f "$cmux_disconnect_scrollback_file" ]; then
            /bin/cat -- "$cmux_disconnect_scrollback_file" 2>/dev/null || true
            printf '\\n'
          fi
          /bin/rm -f -- "$cmux_disconnect_scrollback_file" 2>/dev/null || true
          printf '\\033]1337;CurrentDir=kitty-shell-cwd://%s/.cmux/session-scrollback-replay/%s/end\\007' "$cmux_disconnect_host" "$cmux_disconnect_scrollback_token"
          printf '\\033]1337;CurrentDir=kitty-shell-cwd://%s%s\\007' "$cmux_disconnect_host" "$PWD"
        fi
        # Append newline + color codes ourselves rather than trusting the translator to
        # preserve them in every locale.
        printf '\\033[1;33m' >&2
        printf "$cmux_disconnect_ended_format" "$cmux_disconnect_target" >&2
        printf '\\033[0m\\n' >&2
        # Remove ourselves so /tmp doesn't accumulate these wrappers across sessions.
        /bin/rm -f -- "$0" 2>/dev/null || true
        if [ -n "$cmux_disconnect_reconnect_command" ]; then
          printf '\\033[2m%s\\033[0m\\n\\n' "$cmux_disconnect_reconnect_line" >&2
          IFS= read -r _ || exit 0
          cmux_reconnect_cli="${CMUX_BUNDLED_CLI_PATH:-}"
          if [ -z "$cmux_reconnect_cli" ] || [ ! -x "$cmux_reconnect_cli" ]; then
            cmux_reconnect_cli="$(command -v cmux 2>/dev/null || true)"
          fi
          cmux_reconnect_socket="${CMUX_SOCKET_PATH:-${CMUX_SOCKET:-}}"
          if [ -n "$cmux_reconnect_cli" ] && [ -n "$cmux_reconnect_socket" ] && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
            cmux_reconnect_payload="{\\"workspace_id\\":\\"$CMUX_WORKSPACE_ID\\""
            if [ -n "${CMUX_SURFACE_ID:-}" ]; then
              cmux_reconnect_payload="$cmux_reconnect_payload,\\"surface_id\\":\\"$CMUX_SURFACE_ID\\""
            fi
            cmux_reconnect_payload="$cmux_reconnect_payload}"
            if "$cmux_reconnect_cli" --socket "$cmux_reconnect_socket" rpc workspace.remote.reconnect "$cmux_reconnect_payload" >/dev/null 2>&1; then
              exec /bin/sh -lc "$cmux_disconnect_reconnect_command"
            fi
          fi
          printf '\\033[2m%s\\033[0m\\n' "$cmux_disconnect_reconnect_unavailable_line" >&2
          while IFS= read -r _; do :; done
          exit 0
        fi
        printf '\\033[2m%s\\033[0m\\n' "$cmux_disconnect_reconnect_unavailable_line" >&2
        while IFS= read -r _; do :; done
        exit 0

        """
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL.path
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            return nil
        }
    }
}
