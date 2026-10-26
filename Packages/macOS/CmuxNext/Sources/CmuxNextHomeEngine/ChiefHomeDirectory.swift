public import CmuxNextAgentPane
import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// The Chief homes of this Mac by their agent tab host, `chief:<home id>` (#25262). A subagent tab
/// keeps the home it was made under (NIGHTLY's per-build home before it moved to the shared one, a
/// tagged build's home), so a tab may name a home other than the app's. The homes are the
/// directories of the Chief root (``ChiefHome/chiefRoot(environment:userHome:)``, and its
/// `isolated/`), read on the files lane, never on the main thread, and read again on a miss (a home
/// made since), at most once per `rescanInterval`. Each home's pane host is made once, by one lookup.
public actor ChiefHomeDirectory {
    /// A Chief home's own acpmux as a tab's pane host.
    struct OwnAcpmux: Sendable {
        let environment: AcpmuxEnvironment?
        let host: any AgentPaneHostProviding
        let acpmuxHome: URL
    }

    private let parents: [URL]
    private let work: BackgroundWork
    /// The least time between two reads of `parents` after a miss.
    private let rescanInterval: Duration
    /// The acpmux environment of a Chief home (the app's bundled acpmux with its `ACPMUX_HOME`).
    /// It may read the disk: it runs on the files lane.
    private let environment: @Sendable (ChiefHome) -> AcpmuxEnvironment?
    /// The pane host of a Chief home's own acpmux. `startsDaemons` is false while a brain host
    /// holds that home: its Chief host owns the daemon, which a tab only attaches to (cx-ebm.54), so
    /// this app never starts another live build's acpmux. A home no brain holds (NIGHTLY's old
    /// per-build home, a tagged build that quit) has no owner: its daemon starts again for the tab,
    /// as NIGHTLY's own acpmux does after its move to the app's.
    private let ownHost: @Sendable (_ environment: AcpmuxEnvironment?, _ startsDaemons: Bool) -> any AgentPaneHostProviding
    private var roots: [String: URL] = [:]
    private var lastScan: ContinuousClock.Instant?
    private var lookups: [String: Task<OwnAcpmux?, Never>] = [:]

    public init(parents: [URL], work: BackgroundWork, rescanInterval: Duration = .seconds(10),
                environment: @escaping @Sendable (ChiefHome) -> AcpmuxEnvironment?,
                ownHost: @escaping @Sendable (_ environment: AcpmuxEnvironment?, _ startsDaemons: Bool) -> any AgentPaneHostProviding = {
                    AcpmuxHost(environment: $0, startsDaemons: $1)
                }) {
        self.parents = parents
        self.work = work
        self.rescanInterval = rescanInterval
        self.environment = environment
        self.ownHost = ownHost
    }

    /// The directories that hold the Chief homes beside `home`: its parent, the Chief root and
    /// that root's `isolated/`.
    public nonisolated static func homeParents(of home: ChiefHome, root: URL = ChiefHome.chiefRoot()) -> [URL] {
        var seen = Set<String>()
        return [home.root.deletingLastPathComponent(), root, root.appendingPathComponent("isolated", isDirectory: true)]
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The router of Chief home `host`'s sessions over `fallback` (this Mac's acpmux), nil when no
    /// Chief home of this Mac has that id.
    func router(for host: String, fallback: any AgentPaneHostProviding) async -> (any AgentPaneHostProviding)? {
        guard let own = await ownAcpmux(of: host) else { return nil }
        let tag = "optchat-chief:" + host.dropFirst(ChiefHome.tabHostPrefix.count)
        return AcpmuxChiefSessionRouter(local: fallback, chief: own.host, chiefEnvironment: own.environment,
                                        sessionsHome: own.acpmuxHome, parentTag: tag)
    }

    private func ownAcpmux(of host: String) async -> OwnAcpmux? {
        if let lookup = lookups[host] { return await lookup.value }
        let lookup = Task { await self.lookUp(host) }
        lookups[host] = lookup
        let own = await lookup.value
        // A miss (or a lookup cut short) is asked again later.
        if own == nil { lookups[host] = nil }
        return own
    }

    private func lookUp(_ host: String) async -> OwnAcpmux? {
        if roots[host] == nil, lastScan.map({ ContinuousClock.now - $0 >= rescanInterval }) ?? true {
            let parents = parents
            guard let found = try? await work.run(.userVisible, mayBlock: .files, { Self.homes(in: parents) }) else { return nil }
            lastScan = ContinuousClock.now
            roots.merge(found) { kept, _ in kept }
        }
        guard let root = roots[host] else { return nil }
        let home = ChiefHome(root: root, isolated: false), environment = environment
        // Resolving acpmux looks at its binaries on disk; the host lock is a file lock.
        guard let read = try? await work.run(.userVisible, mayBlock: .files, {
            (environment: environment(home), owned: home.hostRuns)
        }) else { return nil }
        return OwnAcpmux(environment: read.environment, host: ownHost(read.environment, !read.owned), acpmuxHome: home.acpmuxHome)
    }

    /// Every directory under `parents` by its `chief:<home id>`. It reads the disk.
    nonisolated static func homes(in parents: [URL]) -> [String: URL] {
        var homes: [String: URL] = [:]
        for parent in parents {
            for name in (try? FileManager.checked.contentsOfDirectory(atPath: parent.path)) ?? [] where !name.hasPrefix(".") {
                let root = parent.appendingPathComponent(name, isDirectory: true)
                var directory: ObjCBool = false
                guard FileManager.checked.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { continue }
                let id = ChiefHome.tabHost(muxHome: root)
                if homes[id] == nil { homes[id] = root }
            }
        }
        return homes
    }
}
