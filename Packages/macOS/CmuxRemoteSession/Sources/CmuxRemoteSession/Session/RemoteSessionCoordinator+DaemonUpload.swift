internal import CmuxFoundation
internal import Foundation

// Installs cmuxd-remote through the same SSH exec channel used by bootstrap.
// No SFTP subsystem or remote scp executable is required: the local binary is
// streamed to `cat`, then the existing chmod-and-rename step publishes it
// atomically at the versioned destination.
extension RemoteSessionCoordinator {
    // A daemon binary is small enough that a bounded throughput estimate is
    // more useful than a fixed wall clock. The floor handles SSH setup and the
    // cap bounds how long a stalled transfer can hold the coordinator.
    static let daemonUploadMinimumThroughputBytesPerSecond: Double = 32 * 1024
    static let daemonUploadMinimumTimeout: TimeInterval = 90
    static let daemonUploadTimeoutGrace: TimeInterval = 30
    static let daemonUploadMaximumTimeout: TimeInterval = 15 * 60

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
        temp_path=\(quotedRemoteTempPath)
        pid_path=\(quotedRemoteTempPIDPath)
        printf '%s\\n' "$$" > "$pid_path"
        trap 'if [ -n "$cat_pid" ]; then kill "$cat_pid" 2>/dev/null || true; fi; rm -f -- "$temp_path" "$pid_path"; exit 1' HUP INT TERM
        cat > "$temp_path" &
        cat_pid=$!
        printf '%s\\n' "$cat_pid" > "$pid_path"
        wait "$cat_pid"
        cat_status=$?
        cat_pid=
        rm -f -- "$pid_path"
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
                timeout: Self.daemonUploadTimeout(for: localBinary)
            )
        } catch {
            let detail = Self.safeRemoteProcessFailureDetail(error)
            cleanupRemoteDaemonTemporaryUploadsLocked(
                remotePath: remotePath,
                currentTemporaryPath: remoteTempPath
            )
            let message: String
            if let detail {
                message = String(
                    localized: "remoteDaemon.upload.transferFailedWithDetail",
                    defaultValue: "failed to upload cmuxd-remote: \(detail)"
                )
            } else {
                message = String(
                    localized: "remoteDaemon.upload.transferFailed",
                    defaultValue: "failed to upload cmuxd-remote"
                )
            }
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
            throw NSError(domain: "cmux.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "remoteDaemon.upload.transferFailedWithDetail",
                    defaultValue: "failed to upload cmuxd-remote: \(detail)"
                ),
            ])
        }

        let finalizeScript = """
        chmod 755 \(remoteTempPath.shellSingleQuoted) && \
        mv \(remoteTempPath.shellSingleQuoted) \(remotePath.shellSingleQuoted)
        """
        let finalizeCommand = "sh -c \(finalizeScript.shellSingleQuoted)"
        let finalizeResult: RemoteCommandResult
        do {
            finalizeResult = try sshExec(
                arguments: daemonBootstrapSSHArguments() + [configuration.destination, finalizeCommand],
                timeout: 12
            )
        } catch {
            let detail = Self.safeRemoteProcessFailureDetail(error)
            cleanupRemoteDaemonTemporaryUploadsLocked(
                remotePath: remotePath,
                currentTemporaryPath: remoteTempPath
            )
            let message: String
            if let detail {
                message = String(
                    localized: "remoteDaemon.upload.installFailedWithDetail",
                    defaultValue: "failed to install remote daemon binary: \(detail)"
                )
            } else {
                message = String(
                    localized: "remoteDaemon.upload.installFailed",
                    defaultValue: "failed to install remote daemon binary"
                )
            }
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
            throw NSError(domain: "cmux.remote.daemon", code: 32, userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "remoteDaemon.upload.installFailedWithDetail",
                    defaultValue: "failed to install remote daemon binary: \(detail)"
                ),
            ])
        }
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
        for cmux_pid_file in \(quotedRemotePath).tmp-*.pid; do
          [ -r "$cmux_pid_file" ] || continue
          cmux_pid="$(cat "$cmux_pid_file" 2>/dev/null || true)"
          case "$cmux_pid" in
            ''|0|1|*[!0-9]*) ;;
            *) [ "$cmux_pid" = "$$" ] || kill "$cmux_pid" 2>/dev/null || true ;;
          esac
        done
        """
        let specificRemoveTargets: String
        if let currentTemporaryPath {
            let quotedCurrentTemporaryPath = currentTemporaryPath.shellSingleQuoted
            let quotedCurrentPIDPath = "\(currentTemporaryPath).pid".shellSingleQuoted
            specificRemoveTargets =
                " \(quotedCurrentTemporaryPath) \(quotedCurrentPIDPath)"
        } else {
            specificRemoveTargets = ""
        }
        return """
        \(processCleanup)
        rm -f -- \(quotedRemotePath).tmp-* \(quotedRemotePath).tmp-*.pid\(specificRemoveTargets)
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
