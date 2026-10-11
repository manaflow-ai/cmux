import Foundation

extension AgentPaneModel {
    /// Shell mode's requests (``AgentPaneShell``): `shell.run`, `shell.read` and `shell.stop`.
    func respondToShell(_ request: AgentPaneRequest) async -> [String: Any] {
        switch request {
        case .shellRun(let command, let cwd):
            // Page script cannot make a gesture: only the user's Return or click runs a command.
            guard transport.gestures.consume() else {
                return AgentPaneReply.failure(code: "shell.gesture_required", message: Self.shellGestureMessage)
            }
            do {
                return AgentPaneReply.success(["id": try shell.run(command, cwd: cwd)])
            } catch {
                return AgentPaneReply.failure(code: "shell.failed", message: Self.shellFailureMessage(error))
            }
        case .shellRead(let id, let after):
            do {
                let chunk = try await shell.read(id, after: after)
                var value: [String: Any] = ["output": chunk.output, "next": chunk.next]
                if chunk.truncated { value["truncated"] = true }
                if let exit = chunk.exit {
                    var exitValue: [String: Any] = [:]
                    if let code = exit.code { exitValue["code"] = Int(code) }
                    if let signal = exit.signal { exitValue["signal"] = Int(signal) }
                    value["exit"] = exitValue
                }
                return AgentPaneReply.success(value)
            } catch {
                return AgentPaneReply.failure(code: "shell.failed", message: Self.shellFailureMessage(error))
            }
        case .shellStop(let id):
            shell.stop(id)
            return AgentPaneReply.success()
        default:
            return AgentPaneReply.failure(code: "shell.failed", message: Self.shellFailureMessage(AgentPaneShell.Failure.unknownRun))
        }
    }
}
