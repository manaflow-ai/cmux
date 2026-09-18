internal import Foundation

// The stdio hello is a separate bootstrap phase: upload/finalize can succeed
// while the remote kernel still rejects execution of the promoted artifact.
extension RemoteSessionCoordinator {
    /// Executes the remote daemon hello request and parses its capability response.
    func helloRemoteDaemonLocked(remotePath: String) throws -> DaemonHello {
        let request = #"{"id":1,"method":"hello","params":{}}"#
        let script = "printf '%s\\n' \(request.shellSingleQuoted) | \(remotePath.shellSingleQuoted) serve --stdio"
        let command = "sh -c \(script.shellSingleQuoted)"
        let result = try sshExec(
            arguments: daemonBootstrapSSHArguments() + [configuration.destination, command],
            timeout: 12
        )
        debugLog(
            "remote.bootstrap.hello.result status=\(result.status) " +
                "stdoutBytes=\(result.stdout.utf8.count) stderrBytes=\(result.stderr.utf8.count)"
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ??
                "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "failed to start remote daemon: \(detail)",
            ])
        }

        let responseLine = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        guard !responseLine.isEmpty,
              let data = responseLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            debugLog(
                "remote.bootstrap.hello.invalidJSON responseBytes=\(responseLine.utf8.count) " +
                    "stdoutBytes=\(result.stdout.utf8.count)"
            )
            throw NSError(domain: "cmux.remote.daemon", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello returned invalid JSON",
            ])
        }

        if let ok = payload["ok"] as? Bool, !ok {
            let errorMessage: String = {
                if let errorObject = payload["error"] as? [String: Any],
                   let message = errorObject["message"] as? String,
                   !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                return "hello call failed"
            }()
            throw NSError(domain: "cmux.remote.daemon", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello failed: \(errorMessage)",
            ])
        }

        let resultObject = payload["result"] as? [String: Any] ?? [:]
        let name = (resultObject["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (resultObject["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let capabilities = (resultObject["capabilities"] as? [String]) ?? []
        return DaemonHello(
            name: (name?.isEmpty == false ? name! : "cmuxd-remote"),
            version: (version?.isEmpty == false ? version! : "dev"),
            capabilities: capabilities,
            remotePath: remotePath
        )
    }
}
