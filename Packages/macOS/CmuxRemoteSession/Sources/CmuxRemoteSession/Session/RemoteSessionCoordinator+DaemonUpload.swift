internal import CmuxFoundation
internal import CryptoKit
internal import Foundation

// Installs cmuxd-remote through the same SSH exec channel used by bootstrap.
// No SFTP subsystem or remote scp executable is required: the local binary is
// streamed to `cat`, then the existing chmod-and-rename step publishes it
// atomically at the versioned destination.
extension RemoteSessionCoordinator {
    private struct LocalDaemonArtifact {
        let byteCount: Int64
        let sha256: String
    }

    // A daemon binary is small enough that a bounded throughput estimate is
    // more useful than a fixed wall clock. The floor handles SSH setup and the
    // cap bounds how long a stalled transfer can hold the coordinator.
    static let daemonUploadMinimumThroughputBytesPerSecond: Double = 32 * 1024
    static let daemonUploadMinimumTimeout: TimeInterval = 90
    static let daemonUploadTimeoutGrace: TimeInterval = 30
    static let daemonUploadMaximumTimeout: TimeInterval = 15 * 60
    static let daemonUploadStallCheckIntervalSeconds = 5
    static let daemonUploadStallCheckLimit = 12

    static func daemonUploadTimeout(for localBinary: URL) -> TimeInterval {
        let resourceValues = try? localBinary.resourceValues(forKeys: [.fileSizeKey])
        return daemonUploadTimeout(forByteCount: Int64(resourceValues?.fileSize ?? 0))
    }

    static func daemonUploadTimeout(forByteCount byteCount: Int64) -> TimeInterval {
        guard byteCount > 0 else { return daemonUploadMinimumTimeout }
        let scaledDeadline = Double(byteCount) / daemonUploadMinimumThroughputBytesPerSecond +
            daemonUploadTimeoutGrace
        return min(
            daemonUploadMaximumTimeout,
            max(daemonUploadMinimumTimeout, scaledDeadline)
        )
    }

    func uploadRemoteDaemonBinaryLocked(localBinary: URL, location: RemoteDaemonInstallLocation) throws {
        let artifact = try localDaemonArtifact(for: localBinary)
        let remotePath = location.absolutePath
        let remoteDirectory = location.directory
        let remoteTempPath = "\(remotePath).tmp-\(UUID().uuidString.prefix(8))"
        let remoteTempPIDPath = "\(remoteTempPath).pid"
        debugLog(
            "remote.upload.begin transport=ssh-stdin local=\(localBinary.path) " +
                "remoteTemp=\(remoteTempPath) remote=\(remotePath)"
        )

        let mkdirScript = "mkdir -p \(remoteDirectory.shellSingleQuoted) && " +
            Self.remoteDaemonTemporaryCleanupScript(remotePath: remotePath)
        let mkdirCommand = "sh -c \(mkdirScript.shellSingleQuoted)"
        let mkdirResult: RemoteCommandResult
        do {
            mkdirResult = try sshExec(
                arguments: daemonBootstrapSSHArguments() + [configuration.destination, mkdirCommand],
                timeout: 12
            )
        } catch {
            let detail = Self.safeRemoteProcessFailureDetail(error)
            debugLog("remote.bootstrap.upload.failed detail=\(detail ?? "unknown")")
            let message: String
            if let detail {
                message = String(
                    localized: "remoteDaemon.upload.createDirectoryFailedWithDetail",
                    defaultValue: "failed to create remote daemon directory: \(detail)"
                )
            } else {
                message = String(
                    localized: "remoteDaemon.upload.createDirectoryFailed",
                    defaultValue: "failed to create remote daemon directory"
                )
            }
            throw NSError(domain: "cmux.remote.daemon", code: 30, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        guard mkdirResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: mkdirResult.stderr, stdout: mkdirResult.stdout) ??
                "ssh exited \(mkdirResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 30, userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "remoteDaemon.upload.createDirectoryFailedWithDetail",
                    defaultValue: "failed to create remote daemon directory: \(detail)"
                ),
            ])
        }

        let quotedRemoteTempPath = remoteTempPath.shellSingleQuoted
        let quotedRemoteTempPIDPath = remoteTempPIDPath.shellSingleQuoted
        let uploadScript = """
        cat_pid=
        watchdog_pid=
        temp_path=\(quotedRemoteTempPath)
        pid_path=\(quotedRemoteTempPIDPath)
        lock_path="$pid_path.lock"
        trap 'if [ -n "$cat_pid" ]; then kill "$cat_pid" 2>/dev/null || true; fi; if [ -n "$watchdog_pid" ]; then kill "$watchdog_pid" 2>/dev/null || true; fi; rm -f -- "$temp_path" "$pid_path"; rmdir "$lock_path" 2>/dev/null || true; exit 1' HUP INT TERM
        # POSIX shells give an asynchronous command /dev/null for stdin unless
        # the parent explicitly preserves the descriptor first. Without this
        # dup, cat exits 0 after writing an empty payload even though ssh had
        # a file-backed stdin stream to forward.
        exec 3<&0
        # Keep the shell PID marker for stale-file detection. Recovery never
        # signals a marker PID because numeric PIDs can be reused.
        set -C
        # Create the owner marker atomically after noclobber is enabled.
        if ! printf '%s\\n' "$$" > "$pid_path"; then
          exit 76
        fi
        # Open the payload once with noclobber, then write through the
        # descriptor. This refuses a pre-existing payload symlink or file.
        if ! exec 4> "$temp_path"; then
          exit 76
        fi
        cat <&3 >&4 &
        cat_pid=$!
        (
          stall_checks=0
          previous_size=0
          while kill -0 "$cat_pid" 2>/dev/null; do
            # Serialize the heartbeat with stale-file recovery. mkdir is an
            # atomic directory claim on the remote filesystem.
            if mkdir "$lock_path" 2>/dev/null; then
              if ! touch "$pid_path" 2>/dev/null; then
                rmdir "$lock_path" 2>/dev/null || true
                exit 0
              fi
              rmdir "$lock_path" 2>/dev/null || true
            fi
            current_size="$(wc -c < "$temp_path" 2>/dev/null || printf '0')"
            set -- $current_size
            current_size="${1:-0}"
            if [ "$current_size" -ge \(artifact.byteCount) ]; then exit 0; fi
            if [ "$current_size" -gt "$previous_size" ]; then
              previous_size="$current_size"
              stall_checks=0
            else
              stall_checks=$((stall_checks + 1))
            fi
            if [ "$stall_checks" -ge \(Self.daemonUploadStallCheckLimit) ]; then
              # Abort silently. The local SSH result is mapped to a generic
              # user error and bounded detail is retained in debugLog.
              # without byte progress
              kill "$cat_pid" 2>/dev/null || true
              exit 0
            fi
            sleep \(Self.daemonUploadStallCheckIntervalSeconds)
          done
        ) &
        watchdog_pid=$!
        wait "$cat_pid"
        cat_status=$?
        cat_pid=
        exec 3<&-
        exec 4>&-
        if [ -n "$watchdog_pid" ]; then kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true; fi
        watchdog_pid=
        if [ "$cat_status" -ne 0 ]; then rm -f -- "$temp_path"; fi
        trap - HUP INT TERM
        exit "$cat_status"
        """
        let uploadCommand = "sh -c \(uploadScript.shellSingleQuoted)"
        let uploadResult: RemoteCommandResult
        do {
            uploadResult = try sshExec(
                arguments: daemonBootstrapSSHArguments() + [configuration.destination, uploadCommand],
                stdinFile: localBinary,
                timeout: Self.daemonUploadTimeout(forByteCount: artifact.byteCount)
            )
        } catch {
            let detail = Self.safeRemoteProcessFailureDetail(error)
            debugLog("remote.bootstrap.upload.failed detail=\(detail ?? "unknown")")
            cleanupRemoteDaemonTemporaryUploadsLocked(
                remotePath: remotePath,
                currentTemporaryPath: remoteTempPath
            )
            let message: String
            message = String(
                localized: "remoteDaemon.upload.transferFailed",
                defaultValue: "failed to upload remote daemon"
            )
            throw NSError(domain: "cmux.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        guard uploadResult.status == 0 else {
            cleanupRemoteDaemonTemporaryUploadsLocked(
                remotePath: remotePath,
                currentTemporaryPath: remoteTempPath
            )
            let detail = Self.bestErrorLine(stderr: uploadResult.stderr, stdout: uploadResult.stdout) ??
                "ssh exited \(uploadResult.status)"
            debugLog("remote.bootstrap.upload.failed status=\(uploadResult.status) detail=\(detail)")
            throw NSError(domain: "cmux.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "remoteDaemon.upload.transferFailed",
                    defaultValue: "failed to upload remote daemon"
                ),
            ])
        }

        let finalizeScript = Self.remoteDaemonFinalizeScript(
            remoteTempPath: remoteTempPath,
            remotePath: remotePath,
            expectedByteCount: artifact.byteCount,
            expectedSHA256: artifact.sha256
        )
        let finalizeCommand = "sh -c \(finalizeScript.shellSingleQuoted)"
        let finalizeResult: RemoteCommandResult
        do {
            finalizeResult = try sshExec(
                arguments: daemonBootstrapSSHArguments() + [configuration.destination, finalizeCommand],
                timeout: 12
            )
        } catch {
            let detail = Self.safeRemoteProcessFailureDetail(error)
            debugLog("remote.bootstrap.install.failed detail=\(detail ?? "unknown")")
            cleanupRemoteDaemonTemporaryUploadsLocked(
                remotePath: remotePath,
                currentTemporaryPath: remoteTempPath
            )
            let message = Self.remoteDaemonInstallFailureMessage(detail: nil)
            throw NSError(domain: "cmux.remote.daemon", code: 32, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        guard finalizeResult.status == 0 else {
            cleanupRemoteDaemonTemporaryUploadsLocked(
                remotePath: remotePath,
                currentTemporaryPath: remoteTempPath
            )
            let detail = Self.bestErrorLine(stderr: finalizeResult.stderr, stdout: finalizeResult.stdout) ??
                "ssh exited \(finalizeResult.status)"
            debugLog("remote.bootstrap.install.failed status=\(finalizeResult.status) detail=\(detail)")
            let integrityFailure = Self.isRemoteDaemonIntegrityFailure(finalizeResult)
            let message = integrityFailure
                ? Self.remoteDaemonIntegrityFailureMessage(detail: nil)
                : Self.remoteDaemonInstallFailureMessage(detail: nil)
            throw NSError(domain: "cmux.remote.daemon", code: integrityFailure ? 33 : 32, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }

    /// Builds the fail-closed remote verification and atomic promotion script.
    /// The temporary file is never renamed until both byte count and SHA-256
    /// match the local artifact; missing hash utilities are an explicit error.
    static func remoteDaemonFinalizeScript(
        remoteTempPath: String,
        remotePath: String,
        expectedByteCount: Int64,
        expectedSHA256: String
    ) -> String {
        let expectedSize = String(max(0, expectedByteCount))
        let remoteTempPIDPath = "\(remoteTempPath).pid"
        return """
        temp_path=\(remoteTempPath.shellSingleQuoted)
        pid_path=\(remoteTempPIDPath.shellSingleQuoted)
        final_path=\(remotePath.shellSingleQuoted)
        expected_size=\(expectedSize.shellSingleQuoted)
        expected_sha=\(expectedSHA256.shellSingleQuoted)
        if [ ! -s "$temp_path" ]; then
          exit 74
        fi
        set -- $(wc -c < "$temp_path" 2>/dev/null)
        actual_size="${1:-}"
        case "$actual_size" in
          ''|*[!0-9]*)
            exit 74
            ;;
        esac
        if [ "$actual_size" != "$expected_size" ]; then
          exit 74
        fi
        actual_sha=
        if command -v sha256sum >/dev/null 2>&1; then
          set -- $(sha256sum "$temp_path" 2>/dev/null)
          actual_sha="${1:-}"
        elif command -v shasum >/dev/null 2>&1; then
          set -- $(shasum -a 256 "$temp_path" 2>/dev/null)
          actual_sha="${1:-}"
        else
          exit 75
        fi
        if [ "$actual_sha" != "$expected_sha" ]; then
          exit 74
        fi
        if chmod 755 "$temp_path" && mv -f "$temp_path" "$final_path"; then
          # Keep the marker until promotion succeeds. If this shell is
          # interrupted before this point, age-based recovery can reclaim the
          # payload instead of leaving an unmarked temporary file.
          rm -f -- "$pid_path" || true
        else
          exit 1
        fi
        """
    }

    private func localDaemonArtifact(for localBinary: URL) throws -> LocalDaemonArtifact {
        let data: Data
        do {
            data = try Data(contentsOf: localBinary, options: [.mappedIfSafe])
        } catch {
            throw Self.remoteDaemonIntegrityFailure(
                detail: "could not read local cmuxd-remote: \(error.localizedDescription)"
            )
        }
        guard !data.isEmpty else {
            throw Self.remoteDaemonIntegrityFailure(detail: "local cmuxd-remote is empty")
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return LocalDaemonArtifact(byteCount: Int64(data.count), sha256: digest)
    }

    private static func remoteDaemonIntegrityFailure(detail _: String) -> NSError {
        NSError(domain: "cmux.remote.daemon", code: 33, userInfo: [
            NSLocalizedDescriptionKey: remoteDaemonIntegrityFailureMessage(detail: nil),
        ])
    }

    private static func isRemoteDaemonIntegrityFailure(_ result: RemoteCommandResult) -> Bool {
        let stderr = result.stderr.lowercased()
        return result.status == 74 || result.status == 75 ||
            stderr.contains("cmux daemon verification failed") ||
            stderr.contains("sha256") ||
            stderr.contains("sha-256") ||
            stderr.contains("checksum") ||
            stderr.contains("size mismatch")
    }

    private static func remoteDaemonIntegrityFailureMessage(detail: String?) -> String {
        guard let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(
                localized: "remoteDaemon.upload.verifyFailed",
                defaultValue: "remote daemon integrity verification failed"
            )
        }
        return String(
            localized: "remoteDaemon.upload.verifyFailedWithDetail",
            defaultValue: "remote daemon integrity verification failed: \(detail)"
        )
    }

    private static func remoteDaemonInstallFailureMessage(detail: String?) -> String {
        if detail != nil {
            return String(
                localized: "remoteDaemon.upload.installFailedWithDetail",
                defaultValue: "failed to install remote daemon"
            )
        }
        return String(
            localized: "remoteDaemon.upload.installFailed",
            defaultValue: "failed to install remote daemon"
        )
    }

    private func cleanupRemoteDaemonTemporaryUploadsLocked(
        remotePath: String,
        currentTemporaryPath: String
    ) {
        let cleanupScript = Self.remoteDaemonTemporaryCleanupScript(
            remotePath: remotePath,
            currentTemporaryPath: currentTemporaryPath
        )
        let cleanupCommand = "sh -c \(cleanupScript.shellSingleQuoted)"
        do {
            let result = try sshExec(
                arguments: daemonBootstrapSSHArguments() + [configuration.destination, cleanupCommand],
                timeout: 8
            )
            guard result.status == 0 else {
                let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ??
                    "ssh exited \(result.status)"
                debugLog("remote.upload.cleanup.failed detail=\(detail) remote=\(remotePath)")
                return
            }
            debugLog("remote.upload.cleanup.completed remote=\(remotePath)")
        } catch {
            debugLog(
                "remote.upload.cleanup.failed detail=\(error.localizedDescription) " +
                    "remote=\(remotePath)"
            )
        }
    }

    static func remoteDaemonTemporaryCleanupScript(
        remotePath: String,
        currentTemporaryPath: String? = nil
    ) -> String {
        let quotedRemotePath = remotePath.shellSingleQuoted
        let processCleanup = """
        cmux_is_fresh() {
          cmux_fresh_marker="$(find "$1" -mmin -30 2>/dev/null)" || return 2
          [ -n "$cmux_fresh_marker" ]
        }
        # Reclaim only markers whose heartbeat is older than the conservative
        # age window. A live marker belongs to a concurrent upload and must
        # not be signaled or glob-deleted. The lock makes the age check and
        # removal one ownership transaction with the upload heartbeat.
        for cmux_pid_file in \(quotedRemotePath).tmp-*.pid; do
          [ -r "$cmux_pid_file" ] || continue
          cmux_lock_path="$cmux_pid_file.lock"
          if [ -e "$cmux_lock_path" ]; then
            cmux_is_fresh "$cmux_lock_path"
            cmux_lock_age_status=$?
            if [ "$cmux_lock_age_status" -ne 1 ]; then
              continue
            fi
            rmdir "$cmux_lock_path" 2>/dev/null || continue
          fi
          if ! mkdir "$cmux_lock_path" 2>/dev/null; then
            continue
          fi
          cmux_is_fresh "$cmux_pid_file"
          cmux_marker_age_status=$?
          if [ "$cmux_marker_age_status" -ne 1 ]; then
            rmdir "$cmux_lock_path" 2>/dev/null || true
            continue
          fi
          cmux_temp_path="${cmux_pid_file%.pid}"
          rm -f -- "$cmux_temp_path" "$cmux_pid_file"
          rmdir "$cmux_lock_path" 2>/dev/null || true
        done
        """
        let currentCleanup: String
        if let currentTemporaryPath {
            let quotedCurrentTemporaryPath = currentTemporaryPath.shellSingleQuoted
            let quotedCurrentPIDPath = "\(currentTemporaryPath).pid".shellSingleQuoted
            currentCleanup = """
            # A numeric PID is not a process identity. It can be reused by an
            # unrelated process between reading the marker and signaling it.
            # Never signal from a marker; the upload owner's trap handles its
            # own children, while recovery only removes its files.
            rm -f -- \(quotedCurrentTemporaryPath) \(quotedCurrentPIDPath)
            rmdir \(quotedCurrentPIDPath).lock 2>/dev/null || true
            """
        } else {
            currentCleanup = ":"
        }
        return """
        \(processCleanup)
        \(currentCleanup)
        """
    }

    static func safeRemoteProcessFailureDetail(_ error: any Error) -> String? {
        let nsError = error as NSError
        guard nsError.domain == "cmux.remote.process" else { return nil }
        let description = nsError.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return nil }
        if nsError.code == 1,
           let prefix = description.split(separator: ":", maxSplits: 1).first,
           !prefix.isEmpty {
            return String(prefix)
        }
        return nsError.code == 2 ? description : nil
    }
}
