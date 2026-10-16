import Foundation

/// Sessions waiting for the agent hook install, and whether one install is out.
struct RemoteTmuxAgentHookInstallBatch {
    var inFlight = false
    var waiting: [String] = []
}

/// Agent hook installs, one payload for many sessions.
///
/// Every mirrored session asks for the install when it attaches and again after each
/// reconnect, all in the same turn. The installer carries the helper itself, about 17 KB, so
/// a copy per session put a quarter of a megabyte on the control stream of a 15-session host
/// at every attach. One install goes out at once; sessions that ask while it is out wait for
/// tmux to answer it and then go out together in the next one.
@MainActor
extension RemoteTmuxControlConnection {
    func requestAgentHookInstall(sessionTarget: String) {
        if !agentHookInstalls.waiting.contains(sessionTarget) {
            agentHookInstalls.waiting.append(sessionTarget)
        }
        guard !agentHookInstalls.inFlight else { return }
        sendWaitingAgentHookInstalls()
    }

    /// Sends one install for every waiting session. Waiting sessions stay queued when the
    /// stream cannot send; the reconnect republishes them and that request sends the batch.
    private func sendWaitingAgentHookInstalls() {
        guard !agentHookInstalls.waiting.isEmpty else { return }
        guard let command = RemoteTmuxAgentHookInstaller.installCommand(
            sessionTargets: agentHookInstalls.waiting
        ) else {
            agentHookInstalls.waiting.removeAll()
            return
        }
        // The completion fires once: on tmux's answer, or on a stream reset.
        let sent = sendTracked(command) { [weak self] _ in
            guard let self else { return }
            self.agentHookInstalls.inFlight = false
            self.sendWaitingAgentHookInstalls()
        }
        guard sent else { return }
        agentHookInstalls.waiting.removeAll()
        agentHookInstalls.inFlight = true
    }
}
