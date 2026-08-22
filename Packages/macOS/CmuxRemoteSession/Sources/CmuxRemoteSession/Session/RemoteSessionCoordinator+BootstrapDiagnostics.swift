internal import Foundation
internal import OSLog

nonisolated private let remoteBootstrapLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "RemoteDaemonBootstrap"
)

extension RemoteSessionCoordinator {
    /// Removes a known versioned install before a repair upload.
    func removeRemoteDaemonInstallLocked(remotePath: String) throws {
        let script = "rm -f -- \(remotePath.shellSingleQuoted)"
        let command = "sh -c \(script.shellSingleQuoted)"
        let result: RemoteCommandResult
        do {
            result = try sshExec(
                arguments: daemonBootstrapSSHArguments() + [configuration.destination, command],
                timeout: 12
            )
        } catch {
            throw NSError(domain: "cmux.remote.daemon", code: 34, userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "remoteDaemon.bootstrap.removeCorruptFailed",
                    defaultValue: "failed to remove corrupt remote daemon install"
                ),
                NSUnderlyingErrorKey: error,
            ])
        }
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ??
                "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 34, userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "remoteDaemon.bootstrap.removeCorruptFailedWithDetail",
                    defaultValue: "failed to remove corrupt remote daemon install: \(detail)"
                ),
            ])
        }
        debugLog("remote.bootstrap.repair.removed remotePath=\(remotePath)")
    }

    /// Collects bounded remote path/size/log-tail diagnostics without masking
    /// the bootstrap failure that triggered the query.
    func remoteDaemonDiagnosticsLocked(remotePath: String, version: String) -> String? {
        let script = Self.remoteDaemonDiagnosticsScript(
            remotePath: remotePath,
            version: version,
            persistentDaemonSlot: configuration.persistentDaemonSlot
        )
        let command = "sh -c \(script.shellSingleQuoted)"
        guard let result = try? sshExec(
            arguments: daemonBootstrapSSHArguments() + [configuration.destination, command],
            timeout: 8
        ), result.status == 0 else {
            return nil
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        return String(output.prefix(6_000))
    }

    /// Builds the remote diagnostic probe used on bootstrap/hello failures.
    static func remoteDaemonDiagnosticsScript(
        remotePath: String,
        version: String,
        persistentDaemonSlot: String?
    ) -> String {
        let safeVersion = normalizedRemotePlatformProbeVersion(version)
        let logPathAssignment: String
        if let slot = normalizedPersistentDaemonSlotForRemoteCleanup(persistentDaemonSlot) {
            logPathAssignment = "log_path=\"$HOME/.cmux/daemon/\(safeVersion)/\(slot)/daemon.log\""
        } else {
            logPathAssignment = "log_path=''"
        }
        return """
        remote_path=\(remotePath.shellSingleQuoted)
        \(logPathAssignment)
        if [ -e "$remote_path" ]; then
          remote_size="$(wc -c < "$remote_path" 2>/dev/null || printf 'unknown')"
          set -- $remote_size
          remote_size="${1:-unknown}"
        else
          remote_size=missing
        fi
        printf 'remote_path=%s\\nremote_size=%s\\n' "$remote_path" "$remote_size"
        if [ -n "$log_path" ] && [ -r "$log_path" ]; then
          printf '%s\\n' 'daemon_log_tail:'
          tail -n 80 "$log_path" 2>/dev/null || true
        else
          printf '%s\\n' 'daemon_log_tail: unavailable'
        fi
        """
    }

    static func annotatedRemoteDaemonBootstrapError(
        _ error: any Error,
        remotePath: String,
        diagnostic: String?
    ) -> NSError {
        let nsError = error as NSError
        var detail = nsError.localizedDescription
        detail += " (remote path: \(remotePath)"
        if let diagnostic, !diagnostic.isEmpty {
            detail += "; diagnostics: \(diagnostic)"
        }
        detail += ")"
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: detail]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] {
            userInfo[NSUnderlyingErrorKey] = underlying
        }
        if let debugDescription = nsError.userInfo[NSDebugDescriptionErrorKey] {
            userInfo[NSDebugDescriptionErrorKey] = debugDescription
        }
        return NSError(domain: nsError.domain, code: nsError.code, userInfo: userInfo)
    }

    static func logHelloRetry(remotePath: String, error: any Error, diagnostic: String?) {
        let diagnosticText = diagnostic?.replacingOccurrences(of: "\n", with: "\\n") ?? "none"
        remoteBootstrapLogger.error(
            "remote.bootstrap.helloRetry remotePath=\(remotePath) detail=\(error.localizedDescription) diagnostic=\(diagnosticText)"
        )
    }
}
