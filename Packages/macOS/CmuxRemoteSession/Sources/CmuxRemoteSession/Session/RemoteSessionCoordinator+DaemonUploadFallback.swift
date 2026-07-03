import Foundation

extension RemoteSessionCoordinator {
    /// Uploads the daemon over a plain ssh exec channel when scp cannot use sftp.
    func uploadRemoteDaemonBinaryViaExecChannelLocked(
        localBinary: URL,
        remoteTempPath: String,
        scpResult: RemoteCommandResult
    ) throws {
        let scpFailureDetail = Self.bestErrorLine(stderr: scpResult.stderr, stdout: scpResult.stdout)
            ?? "scp exited \(scpResult.status)"
        debugLog("remote.upload.scpFailed detail=\(scpFailureDetail) fallback=exec-channel remoteTemp=\(remoteTempPath)")

        let script = "cat > \(remoteTempPath.shellSingleQuoted)"
        let command = "sh -c \(script.shellSingleQuoted)"
        let result: RemoteCommandResult
        do {
            result = try sshExec(
                arguments: ["-T"] + sshCommonArguments(batchMode: true)
                    + ["-o", "RequestTTY=no", configuration.destination, command],
                standardInputFile: localBinary,
                timeout: 60
            )
        } catch {
            throw NSError(domain: "cmux.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "failed to upload cmuxd-remote (scp: \(scpFailureDetail)): \(error.localizedDescription)",
            ])
        }
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "failed to upload cmuxd-remote (scp: \(scpFailureDetail)): \(detail)",
            ])
        }
        debugLog("remote.upload.execChannel.ok remoteTemp=\(remoteTempPath)")
    }
}
