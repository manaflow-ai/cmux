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

    /// The acpmux that runs `record`'s session: the record says who owns it, so a restored tab
    /// attaches to the same daemon.
    init(_ record: AgentSessionRef, localHost: String?, chiefHost: String?) {
        if let localHost, record.host == localHost {
            self = .local
        } else if let chiefHost, record.host == chiefHost {
            self = .chief
        } else {
            self = .remote
        }
    }
}

/// This app's Chief home as an agent tab host: `chief:<home id>` and its acpmux
/// (`ChiefHome.acpmuxHome`, as HomeBrainHost starts it).
struct ChiefHomeAcpmux {
    let host: String
    let paneHost: any AgentPaneHostProviding

    init(home: ChiefHome) {
        host = Self.host(muxHome: home.muxHome)
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        paneHost = AcpmuxHost(environment: AcpmuxEnvironment.resolve(tag: nil, bundledBinDirectory: bin,
                                                                      environment: ["ACPMUX_HOME": home.acpmuxHome.path]))
    }

    /// `chief:<home id>` of the Chief home `muxHome`. The id is optchat-chief
    /// `paths::home_id`: FNV-1a 32 of the path bytes.
    static func host(muxHome: URL) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for byte in muxHome.path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return "chief:" + String(format: "%08x", hash)
    }
}
