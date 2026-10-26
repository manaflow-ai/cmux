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

/// The Chief homes of this Mac by their `chief:<home id>` (#25262): the directories of
/// `~/.cmux/chief` (and its `isolated/`), read on the files lane, never on the main thread, and
/// read again when a host is not found (a home made since). Each home's pane host is made once.
actor ChiefHomeDirectory {
    private let parents: [URL]
    private let work: BackgroundWork
    /// The pane host of a Chief home's own acpmux (its environment); it starts that daemon again
    /// when it ended, as for NIGHTLY's own acpmux after the move to the app's (``ChiefHomeAcpmux``).
    private let ownHost: @Sendable (AcpmuxEnvironment?) -> any AgentPaneHostProviding
    private var roots: [String: URL] = [:]
    private var hosts: [String: (environment: AcpmuxEnvironment?, host: any AgentPaneHostProviding, acpmuxHome: URL)] = [:]

    init(parents: [URL], work: BackgroundWork,
         ownHost: @escaping @Sendable (AcpmuxEnvironment?) -> any AgentPaneHostProviding = { AcpmuxHost(environment: $0) }) {
        self.parents = parents
        self.work = work
        self.ownHost = ownHost
    }

    /// The directories that hold the Chief homes beside `home`: its parent, the Chief root
    /// (`CMUX_NEXT_CHIEF_ROOT`, else `~/.cmux/chief`) and that root's `isolated/`.
    static func homeParents(of home: ChiefHome, environment: [String: String] = ProcessInfo.processInfo.environment,
                            userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let override = environment["CMUX_NEXT_CHIEF_ROOT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let root = override ?? userHome.appendingPathComponent(".cmux/chief", isDirectory: true)
        var seen = Set<String>()
        return [home.root.deletingLastPathComponent(), root, root.appendingPathComponent("isolated", isDirectory: true)]
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The router of Chief home `host`'s sessions over `fallback` (this Mac's acpmux), nil when no
    /// Chief home of this Mac has that id.
    func router(for host: String, fallback: any AgentPaneHostProviding) async -> (any AgentPaneHostProviding)? {
        guard let own = await ownAcpmux(of: host) else { return nil }
        let tag = "optchat-chief:" + host.dropFirst(ChiefHomeAcpmux.hostPrefix.count)
        return AcpmuxChiefSessionRouter(local: fallback, chief: own.host, chiefEnvironment: own.environment,
                                        sessionsHome: own.acpmuxHome, parentTag: tag)
    }

    private func ownAcpmux(of host: String) async -> (environment: AcpmuxEnvironment?, host: any AgentPaneHostProviding, acpmuxHome: URL)? {
        if let made = hosts[host] { return made }
        if roots[host] == nil { await scan() }
        guard let root = roots[host] else { return nil }
        let home = ChiefHome(root: root, isolated: false)
        // Resolving acpmux looks at its binaries on disk.
        let environment = (try? await work.run(.userVisible, mayBlock: .files) { ChiefHomeAcpmux.environment(home: home) })
        let made = (environment: environment, host: ownHost(environment), acpmuxHome: home.acpmuxHome)
        hosts[host] = made
        return made
    }

    private func scan() async {
        let parents = parents
        let found = (try? await work.run(.userVisible, mayBlock: .files) { Self.homes(in: parents) }) ?? [:]
        roots.merge(found) { kept, _ in kept }
    }

    /// Every directory under `parents` by its `chief:<home id>`.
    nonisolated static func homes(in parents: [URL]) -> [String: URL] {
        var homes: [String: URL] = [:]
        for parent in parents {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] where !name.hasPrefix(".") {
                let root = parent.appendingPathComponent(name, isDirectory: true)
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { continue }
                let id = ChiefHomeAcpmux.host(muxHome: root)
                if homes[id] == nil { homes[id] = root }
            }
        }
        return homes
    }
}

/// The pane host of a tab whose record names a Chief home other than the app's (#25262): its
/// chat opens from that home's acpmux when that home keeps it (``AcpmuxChiefSessionRouter``),
/// else from `fallback`, this Mac's (a home no longer here, a session NIGHTLY's Chief ran on the
/// app's acpmux). Never "belongs to another machine": the home is this Mac's.
nonisolated struct ChiefHomeSessionHost: AgentPaneHostProviding {
    let host: String
    let homes: ChiefHomeDirectory
    let fallback: any AgentPaneHostProviding

    private func resolved() async -> any AgentPaneHostProviding {
        await homes.router(for: host, fallback: fallback) ?? fallback
    }

    func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        try await resolved().handshake(sessionId: sessionId)
    }

    func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        try await resolved().reconnectHandshake(sessionId: sessionId)
    }

    func prewarm() async throws {
        try await fallback.prewarm()
    }

    func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? {
        try await resolved().sessionFolder(sessionId: sessionId)
    }

    func putFile(sessionId: String, name: String, data: Data) async throws -> String {
        try await resolved().putFile(sessionId: sessionId, name: name, data: data)
    }

    func putFile(sessionId: String, name: String, file: URL) async throws -> String {
        try await resolved().putFile(sessionId: sessionId, name: name, file: file)
    }

    /// Restart acpmux replaces this Mac's daemon only (as ``AcpmuxChiefSessionRouter``).
    func restartAcpmux(owner: AcpmuxSocketOwner) async -> Bool {
        await fallback.restartAcpmux(owner: owner)
    }
}

/// This app's Chief home as an agent tab host: `chief:<home id>` and its acpmux
/// (`ChiefHome.acpmuxHome`, as HomeBrainHost starts it).
struct ChiefHomeAcpmux {
    /// Every Chief home's agent tab host starts with it: `chief:<home id>`.
    nonisolated static let hostPrefix = "chief:"
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

    /// `chief:<home id>` of the Chief home `muxHome`. The id is optchat-chief
    /// `paths::home_id`: FNV-1a 32 of the path bytes.
    nonisolated static func host(muxHome: URL) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for byte in muxHome.path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return "chief:" + String(format: "%08x", hash)
    }
}
