internal import CmuxFoundation
internal import Foundation

// Installs cmuxd-remote through the same SSH exec channel used by bootstrap.
// No SFTP subsystem or remote scp executable is required: the local binary is
// streamed to `cat`, then the existing chmod-and-rename step publishes it
// atomically at the versioned destination.
extension RemoteSessionCoordinator {
    func uploadRemoteDaemonBinaryLocked(localBinary: URL, location: RemoteDaemonInstallLocation) throws {
        let remotePath = location.absolutePath
        let remoteDirectory = location.directory
        let remoteTempPath = "\(remotePath).tmp-\(UUID().uuidString.prefix(8))"
        debugLog(
            "remote.upload.begin transport=ssh-stdin local=\(localBinary.path) " +
                "remoteTemp=\(remoteTempPath) remote=\(remotePath)"
        )

        let mkdirScript = "mkdir -p \(remoteDirectory.shellSingleQuoted)"
        let mkdirCommand = "sh -c \(mkdirScript.shellSingleQuoted)"
        let mkdirResult = try sshExec(
            arguments: sshCommonArguments(batchMode: true) + [configuration.destination, mkdirCommand],
            timeout: 12
        )
        guard mkdirResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: mkdirResult.stderr, stdout: mkdirResult.stdout) ??
                "ssh exited \(mkdirResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "failed to create remote daemon directory: \(detail)",
            ])
        }

        let uploadScript = "cat > \(remoteTempPath.shellSingleQuoted)"
        let uploadCommand = "sh -c \(uploadScript.shellSingleQuoted)"
        let uploadResult: RemoteCommandResult
        do {
            uploadResult = try sshExec(
                arguments: sshCommonArguments(batchMode: true) + [configuration.destination, uploadCommand],
                stdinFile: localBinary,
                timeout: 45
            )
        } catch {
            cleanupUploadedRemotePaths([remoteTempPath])
            throw NSError(domain: "cmux.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "failed to upload cmuxd-remote: \(error.localizedDescription)",
            ])
        }
        guard uploadResult.status == 0 else {
            cleanupUploadedRemotePaths([remoteTempPath])
            let detail = Self.bestErrorLine(stderr: uploadResult.stderr, stdout: uploadResult.stdout) ??
                "ssh exited \(uploadResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "failed to upload cmuxd-remote: \(detail)",
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
                arguments: sshCommonArguments(batchMode: true) + [configuration.destination, finalizeCommand],
                timeout: 12
            )
        } catch {
            cleanupUploadedRemotePaths([remoteTempPath])
            throw NSError(domain: "cmux.remote.daemon", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote daemon binary: \(error.localizedDescription)",
            ])
        }
        guard finalizeResult.status == 0 else {
            cleanupUploadedRemotePaths([remoteTempPath])
            let detail = Self.bestErrorLine(stderr: finalizeResult.stderr, stdout: finalizeResult.stdout) ??
                "ssh exited \(finalizeResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote daemon binary: \(detail)",
            ])
        }
    }
}
