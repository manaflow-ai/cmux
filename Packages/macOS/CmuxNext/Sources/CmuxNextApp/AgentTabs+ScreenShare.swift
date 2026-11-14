import CmuxNextAgentActivity
import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

extension AgentTabStore {
    func shareScreen(of key: AgentTabKey, session: String?) -> AgentPaneActionRun {
        guard let registry = actionRegistry, let session, let (record, _) = record(for: key), let daemon = daemon(for: key) else { return .refused(Self.screenShareUnavailable) }
        let host = hostKind(record, listedHere: daemon.isLocal)
        let kind: String = switch host {
        case .local: "local"
        case .chief: "unsupported"
        case .remote: daemon.isLocal ? "remote" : (MachineRegistry.isCloudMachineID(daemon.machineID) ? "cloud" : "remote")
        }
        let lanes = AgentLaneStore.shared
        let links = lanes.links(session)
        return ScreenShareAction.run(registry: registry, session: session, actualSession: sessions[key] ?? record.session ?? "", machineID: daemon.machineID, kind: kind, host: record.host, hostKind: host == .local ? "local" : host == .chief ? "chief" : "remote", peer: links?.peer, registryHost: Self.registryHost(of: daemon), localSummaryCurrent: lanes.live && links != nil, unavailable: Self.screenShareUnavailable)
    }

    private static var screenShareUnavailable: String { String(localized: "screenShare.chat.unavailable", defaultValue: "Screen sharing is not available for this chat’s machine. Open Machines to check its connection.", table: "MiscHandlers", bundle: .module) }
}
