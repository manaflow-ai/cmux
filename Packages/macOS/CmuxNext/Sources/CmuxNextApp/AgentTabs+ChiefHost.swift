import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// Which acpmux an agent tab's pane attaches to.
enum AgentPaneHostKind: Equatable {
    /// This Mac's own acpmux (the app's chats).
    case local
    /// This app's Chief home's acpmux, where the Chief host runs its subagents.
    case chief
    /// Another machine's, through that tab's session daemon.
    case remote
}

extension AgentTabStore {
    /// `chief:<home id>` of the Chief home `muxHome`: the host the Chief host names on its
    /// subagents' tabs. The id is optchat-chief `paths::home_id`: FNV-1a 32 of the path bytes.
    nonisolated static func chiefHost(muxHome: URL) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for byte in muxHome.path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return "chief:" + String(format: "%08x", hash)
    }

    /// The acpmux that runs `record`'s session: the record says who owns it, so a restored tab
    /// attaches to the same daemon.
    func paneHostKind(for record: AgentSessionRef) -> AgentPaneHostKind {
        if let localHost, record.host == localHost { return .local }
        if let chiefHost, record.host == chiefHost { return .chief }
        return .remote
    }

    /// Wires the Chief home's acpmux (`ChiefHome.acpmuxHome`, as HomeBrainHost starts it).
    func wireChiefHome(_ home: ChiefHome) {
        chiefHost = Self.chiefHost(muxHome: home.muxHome)
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        let environment = AcpmuxEnvironment.resolve(tag: nil, bundledBinDirectory: bin,
                                                    environment: ["ACPMUX_HOME": home.acpmuxHome.path])
        chiefPaneHost = AcpmuxHost(environment: environment)
    }
}
