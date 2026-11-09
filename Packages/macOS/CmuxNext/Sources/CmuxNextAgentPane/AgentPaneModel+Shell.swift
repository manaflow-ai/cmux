import Foundation

extension AgentPaneModel {
    /// Shell mode's requests (``AgentPaneShell``): `shell.run`, `shell.read` and `shell.stop`.
    /// A chat on another machine (Cloud, SSH) runs its commands on that machine, in its folder
    /// there, through the machine's daemon (``AgentPaneShell/machine``); never on this Mac (cx-k21v).
    func respondToShell(_ request: AgentPaneRequest) async -> [String: Any] {
        switch request {
        case .shellRun(let command, let cwd):
            // Page script cannot make a gesture: only the user's Return or click runs a command.
            guard transport.gestures.consume() else {
                return AgentPaneReply.failure(code: "shell.gesture_required", message: Self.shellGestureMessage)
            }
            if chatIsElsewhere { return await runOnMachine(command, cwd: cwd) }
            do {
                return AgentPaneReply.success(["id": try shell.run(command, cwd: cwd)])
            } catch {
                return AgentPaneReply.failure(code: "shell.failed", message: Self.shellFailureMessage(error))
            }
        case .shellRead(let id, let after):
            do {
                let chunk: AgentPaneShell.Chunk
                if let link = shell.machineShell(of: id) {
                    chunk = try await link.readShell(id, after: after)
                    if chunk.exit != nil { shell.noteMachineExit(id) }
                } else {
                    chunk = try await shell.read(id, after: after)
                }
                return Self.shellReply(chunk)
            } catch {
                return AgentPaneReply.failure(code: "shell.failed", message: Self.shellFailureMessage(error))
            }
        case .shellStop(let id):
            if let link = shell.machineShell(of: id) { await link.stopShell(id) } else { shell.stop(id) }
            return AgentPaneReply.success()
        default:
            return AgentPaneReply.failure(code: "shell.failed", message: Self.shellFailureMessage(AgentPaneShell.Failure.unknownRun))
        }
    }

    /// A chat elsewhere: only one the handshake marked remote has a machine, and its command goes
    /// to that machine's daemon, in the page's folder or the chat's folder there.
    private func runOnMachine(_ command: String, cwd: String?) async -> [String: Any] {
        guard remoteChat, let link = shell.machine?() else {
            return AgentPaneReply.failure(code: "shell.failed", message: Self.shellFailureMessage(AgentPaneShell.Failure.spawnFailed(0)))
        }
        let folder = cwd ?? sessionId.flatMap(transport.sessions.folder(of:)) ?? handshakeCwd
        do {
            let id = try await link.runShell(command, cwd: folder, scope: shell.machineScope)
            shell.noteMachineRun(id, on: link)
            return AgentPaneReply.success(["id": id])
        } catch {
            return AgentPaneReply.failure(code: "shell.failed", message: Self.shellFailureMessage(error))
        }
    }

    private static func shellReply(_ chunk: AgentPaneShell.Chunk) -> [String: Any] {
        var value: [String: Any] = ["output": chunk.output, "next": chunk.next]
        if chunk.truncated { value["truncated"] = true }
        if let exit = chunk.exit {
            var exitValue: [String: Any] = [:]
            if let code = exit.code { exitValue["code"] = Int(code) }
            if let signal = exit.signal { exitValue["signal"] = Int(signal) }
            value["exit"] = exitValue
        }
        return AgentPaneReply.success(value)
    }
}
