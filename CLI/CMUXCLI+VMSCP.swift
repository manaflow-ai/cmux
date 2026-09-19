import Foundation

extension CMUXCLI {
    struct VMSCPProcessFailure: Error, CustomStringConvertible {
        let status: Int32
        let timedOut: Bool
        let detail: String
        var description: String { "Cloud SSH file transfer failed (exit \(status)): \(detail)" }
    }

    struct VMSCPGrantTransportFailure: Error, CustomStringConvertible {
        let underlying: Error
        var description: String { String(describing: underlying) }
    }

    func reportVMPushFailure(_ error: Error, phase: String, client: SocketClient) {
        let processError = error as? VMSCPProcessFailure
        let failure = processError.map { $0.timedOut ? "timeout" : "process" }
            ?? (error is VMSCPGrantTransportFailure || phase == "request" ? "network" : phase == "snapshot" ? "storage" : "response")
        var params: [String: Any] = ["phase": phase, "failure": failure]
        if let processError { params["error_number"] = Int(processError.status) }
        // Error reporting never replays the failed command and cannot hide it.
        client.close()
        defer { client.close() }
        do {
            let response = try client.sendV2(method: "vm.file_transfer_failure", params: params, responseTimeout: 5)
            if let reference = response["reference"] as? String {
                cliWriteStderr("Cloud diagnostic reference: \(reference)\n")
            }
        } catch {
            cliWriteStderr("Cloud diagnostics could not be sent.\n")
        }
    }

    struct VMSCPTransferEndpoint {
        let host: String
        let port: Int
        let username: String
        let hostPublicKey: String
        let expiresAtUnix: TimeInterval
        var destination: String { "\(username)@\(host)" }
    }

    func vmSCPTransferEndpoint(vmID: String, publicKey: String, client: SocketClient) throws -> VMSCPTransferEndpoint {
        // The app closes idle control sockets after 30 seconds. Each grant
        // request owns a fresh authenticated connection; the SFTP transfer and
        // watcher hold none. Never retry a request with an uncertain outcome.
        client.close()
        defer { client.close() }
        let response: [String: Any]
        do {
            response = try client.sendV2(method: "vm.scp_info", params: ["id": vmID, "public_key": publicKey], responseTimeout: 100)
        } catch {
            if (error as? CLIError)?.isStructuredProtocolResponse == true { throw error }
            throw VMSCPGrantTransportFailure(underlying: error)
        }
        guard let host = response["host"] as? String, host == "127.0.0.1",
              let port = response["port"] as? Int, (1...65535).contains(port),
              let username = response["username"] as? String,
              username.range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil,
              let hostPublicKey = response["host_public_key"] as? String,
              hostPublicKey.range(of: "^ssh-ed25519 [A-Za-z0-9+/]+={0,2}$", options: .regularExpression) != nil,
              let expires = response["expires_at_unix"] as? Double,
              expires.isFinite, expires > Date().timeIntervalSince1970 else {
            throw CLIError(message: "Cloud SCP requires a private connection and a verified SSH host key.")
        }
        return VMSCPTransferEndpoint(host: host, port: port, username: username, hostPublicKey: hostPublicKey, expiresAtUnix: expires)
    }

    @discardableResult
    func runSCPProcess(_ executable: String, arguments: [String], endpoint: VMSCPTransferEndpoint, directory: URL) throws -> String {
        let options = [
            "-F", "/dev/null",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "HostKeyAlgorithms=ssh-ed25519", "-o", "HostKeyAlias=cmux-scp",
            "-o", "UserKnownHostsFile=" + directory.appendingPathComponent("known_hosts").path.replacingOccurrences(of: "%", with: "%%"),
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "IdentitiesOnly=yes", "-i", directory.appendingPathComponent("identity").path,
            "-o", "PreferredAuthentications=publickey", "-o", "BatchMode=yes",
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ForwardAgent=no",
        ]
        let result = CLIProcessRunner.runProcess(executablePath: executable, arguments: options + arguments, stdinText: "", timeout: 10 * 60)
        guard result.status == 0 else {
            let detail = String(result.stderr.suffix(2000))
            throw VMSCPProcessFailure(status: result.status, timedOut: result.timedOut, detail: detail)
        }
        return result.stdout
    }

}
