import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextOnboarding
import Foundation

extension SessionLinkGate {
    /// The app's gate: a session is named from its live lane (this Mac's acpmux and the peers it
    /// mirrors), else from acpmux's session list (a closed one); its machine is this Mac's name or
    /// the peer's machine name. The question shows in the active window.
    @MainActor static func app(_ services: AppServices) -> SessionLinkGate {
        SessionLinkGate(lookup: { @MainActor [weak services] id in
            guard let services else { return nil }
            let host = { (peer: String?) in
                peer.map { services.machines.machineName(peer: $0) ?? $0 } ?? services.agentTabs.localHostName ?? SessionLinkSubject.thisMac
            }
            if let lane = AgentLaneStore.shared.lane(id) {
                return SessionLinkSubject(id: id, title: lane.title, harness: lane.harness, host: host(lane.peer))
            }
            guard let socket = AgentLaneStore.shared.socketPath,
                  let found = try? await AcpmuxSessionPage(socketPath: socket).session(id) else { return nil }
            return SessionLinkSubject(id: id, title: found.chat.title, harness: found.chat.harness, host: host(found.peer))
        }, askOpen: { @MainActor [weak services] subject in
            await SessionLinkGate.ask(subject, in: services?.windows.active?.window)
        })
    }
}
