import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextWakeups
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
    /// This Mac's tabs' host: a session the Chief host runs (an older subagent tab recorded
    /// with this Mac's host) attaches to the Chief home's acpmux, any other to `local`.
    let localRouter: @Sendable (any AgentPaneHostProviding) -> any AgentPaneHostProviding

    /// - Parameters:
    ///   - local: this Mac's pane host; a Chief on the app's own acpmux
    ///     (``ChiefHome/usesAppAcpmux``) attaches its tabs there.
    ///   - work: the app's background work (a heal's follow-up after a busy host's turn).
    ///   - ensureHost: starts the Chief brain host when none runs
    ///     (`ChiefBrainKeeper.ensure`), after a heal stopped the stale one.
    ///   - ownHost: the pane host of the Chief home's own acpmux (its environment) for a Chief
    ///     on the app's acpmux: the daemon its subagents ran on before the move.
    init(home: ChiefHome, local: any AgentPaneHostProviding, work: BackgroundWork, ensureHost: @escaping @Sendable () async -> Void,
         ownHost: @escaping @Sendable (AcpmuxEnvironment?) -> any AgentPaneHostProviding = { AcpmuxHost(environment: $0) }) {
        let host = Self.host(muxHome: home.muxHome)
        self.host = host
        // optchat-chief `brain::parent_tag`: optchat-chief:<home id>.
        let tag = "optchat-chief:" + host.dropFirst("chief:".count)
        let environment = Self.environment(home: home)
        // One daemon: the Chief's new sessions are this Mac's, so their tabs attach like any chat
        // and the app's own handoff heals that daemon. A subagent started before the move
        // (#22900) still runs, or is kept, in the Chief home's own acpmux: its tab attaches there,
        // starting that daemon again when it ended, never to the app's daemon, which lacks the
        // chat and would say "This chat isn't available" (Lawrence 2026-10-21).
        if home.usesAppAcpmux {
            let own = ownHost(environment)
            let sessionsHome = home.acpmuxHome
            let router: @Sendable (any AgentPaneHostProviding) -> any AgentPaneHostProviding = { local in
                AcpmuxChiefSessionRouter(local: local, chief: own, chiefEnvironment: environment, sessionsHome: sessionsHome, parentTag: tag)
            }
            paneHost = router(local)
            localRouter = router
            return
        }
        // The Chief host owns this daemon (it starts it, with the Chief's env): a
        // tab only attaches, never starts one (cx-ebm.54). A daemon that runs a
        // replaced bundle is healed through its owner (ChiefAcpmuxHeal), while the app runs.
        var healReplaced: (@Sendable () async -> Bool)?
        if let environment {
            let heal = ChiefAcpmuxHeal(home: home, environment: environment, work: work, ensureHost: ensureHost)
            healReplaced = { @Sendable () async -> Bool in await heal.heal() }
        }
        let chief = AcpmuxHost(environment: environment, startsDaemons: false, healReplaced: healReplaced)
        paneHost = chief
        localRouter = { local in AcpmuxChiefSessionRouter(local: local, chief: chief, chiefEnvironment: environment, parentTag: tag) }
    }

    /// The acpmux of the Chief home `home` (its socket is `socketPath`), nil without one.
    static func environment(home: ChiefHome) -> AcpmuxEnvironment? {
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        return AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: bin, environment: ["ACPMUX_HOME": home.acpmuxHome.path])
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
