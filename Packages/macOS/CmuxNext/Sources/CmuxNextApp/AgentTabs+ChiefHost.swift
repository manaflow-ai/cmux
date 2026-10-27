import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextHomeEngine
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
    ///
    /// - Parameter listedHere: whether this Mac's own tree lists the tab. Every `chief:<home id>`
    ///   such a tab names is a Chief home of this Mac (#25262): the record keeps the home it was
    ///   made under (NIGHTLY's per-build home before it moved to the shared one, a tagged build's
    ///   home), so it may differ from `chiefHost` and is still never another machine's.
    init(_ record: AgentSessionRef, localHost: String?, chiefHost: String?, listedHere: Bool) {
        if let localHost, record.host == localHost {
            self = .local
        } else if let chiefHost, record.host == chiefHost {
            self = .chief
        } else if listedHere, record.host.hasPrefix(ChiefHomeAcpmux.hostPrefix) {
            self = .chief
        } else {
            self = .remote
        }
    }
}

extension AgentTabStore {
    /// The pane host of a Chief subagent tab whose record names `host` (`chief:<home id>`): the
    /// app's Chief home's, or for another Chief home of this Mac (#25262) that home's acpmux when
    /// it keeps the chat, else this Mac's.
    func chiefTabHost(_ host: String) -> (any AgentPaneHostProviding)? {
        if host == chiefHost { return chiefPaneHost }
        let fallback = localSessionHost ?? self.host
        guard let chiefHomes else { return fallback }
        return ChiefHomeSessionHost(host: host, homes: chiefHomes, fallback: fallback)
    }
}

/// This app's Chief home as an agent tab host: `chief:<home id>` and its acpmux
/// (`ChiefHome.acpmuxHome`, as HomeBrainHost starts it).
struct ChiefHomeAcpmux {
    /// Every Chief home's agent tab host starts with it: `chief:<home id>`.
    nonisolated static let hostPrefix = ChiefHome.tabHostPrefix
    let host: String
    let paneHost: any AgentPaneHostProviding
    /// This Mac's tabs' host: a session the Chief host runs (an older subagent tab recorded
    /// with this Mac's host) attaches to the Chief home's acpmux, any other to `local`.
    let localRouter: @Sendable (any AgentPaneHostProviding) -> any AgentPaneHostProviding

    /// - Parameters:
    ///   - local: this Mac's pane host; a Chief on the app's own acpmux
    ///     (``ChiefHome/usesAppAcpmux``) attaches its tabs there.
    ///   - ensureHost: starts the Chief brain host when none runs
    ///     (`ChiefBrainKeeper.ensure`), after a heal stopped the stale one.
    ///   - ownHost: the pane host of the Chief home's own acpmux (its environment) for a Chief
    ///     on the app's acpmux: the daemon its subagents ran on before the move.
    init(home: ChiefHome, local: any AgentPaneHostProviding, ensureHost: @escaping @Sendable () async -> Void,
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
            let heal = ChiefAcpmuxHeal(home: home, environment: environment, ensureHost: ensureHost)
            healReplaced = { @Sendable () async -> Bool in await heal.heal() }
        }
        let chief = AcpmuxHost(environment: environment, startsDaemons: false, healReplaced: healReplaced)
        paneHost = chief
        localRouter = { local in AcpmuxChiefSessionRouter(local: local, chief: chief, chiefEnvironment: environment, parentTag: tag) }
    }

    /// The acpmux of the Chief home `home` (its socket is `socketPath`), nil without one.
    nonisolated static func environment(home: ChiefHome) -> AcpmuxEnvironment? {
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        return AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: bin, environment: ["ACPMUX_HOME": home.acpmuxHome.path])
    }

    /// `chief:<home id>` of the Chief home `muxHome` (``ChiefHome/tabHost(muxHome:)``).
    nonisolated static func host(muxHome: URL) -> String {
        ChiefHome.tabHost(muxHome: muxHome)
    }
}
