public import CmuxNextAgentPane
import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// The Chief homes of this Mac by their agent tab host, `chief:<home id>` (#25262). A subagent tab
/// keeps the home it was made under (NIGHTLY's per-build home before it moved to the shared one, a
/// tagged build's home), so a tab may name a home other than the app's. The homes are the
/// directories of the Chief root (``ChiefHome/chiefRoot(environment:userHome:)``, and its
/// `isolated/`), and the named Chiefs' homes inside each (`<home>/c/<id>`, cmux-tui chief_brains.rs
/// `brain_home`), read on the files lane, never on the main thread, and read again on a miss (a home
/// made since), at most once per `rescanInterval`. Each home's pane host is made once, by one lookup.
/// A named Chief runs its sessions in its home's acpmux (`<home>/acpmux`, `OPTCHAT_ACPMUX_SHARED`),
/// so its tabs attach there (#27712: they fell back to this Mac's, which lacks the chat).
public actor ChiefHomeDirectory {
    /// A Chief home's own acpmux as a tab's pane hosts: one that may start its daemon and one that
    /// only attaches. Which one a handshake uses is read again each time (``router(for:fallback:)``).
    struct OwnAcpmux: Sendable {
        /// The Chief home the tab names: its brain host's lock says whether the daemon has an owner.
        let home: ChiefHome
        /// The Chief home whose acpmux runs its sessions: `home` itself, or a named Chief's home.
        let owner: ChiefHome
        /// The `ACPMUX_HOME` that runs its sessions (`owner`'s).
        var sessionsHome: URL { owner.acpmuxHome }
        let environment: AcpmuxEnvironment?
        let starting: any AgentPaneHostProviding
        let attaching: any AgentPaneHostProviding
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
    /// as NIGHTLY's own acpmux does after its move to the app's. The app's makes an ``AcpmuxHost``
    /// with its one ``AcpmuxLocalDaemons`` and its approver key, which that host gives each home's daemon it connects.
    private let ownHost: @Sendable (_ environment: AcpmuxEnvironment?, _ startsDaemons: Bool) -> any AgentPaneHostProviding
    /// A Chief home found on disk and the Chief home whose acpmux runs its sessions.
    nonisolated struct Found: Sendable, Equatable {
        let root: URL
        let acpmuxOwner: URL
    }

    private var roots: [String: Found] = [:]
    private var lastScan: ContinuousClock.Instant?
    private var lookups: [String: Task<OwnAcpmux?, Never>] = [:]

    public init(parents: [URL], work: BackgroundWork, rescanInterval: Duration = .seconds(10),
                environment: @escaping @Sendable (ChiefHome) -> AcpmuxEnvironment?,
                ownHost: @escaping @Sendable (_ environment: AcpmuxEnvironment?, _ startsDaemons: Bool) -> any AgentPaneHostProviding) {
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
    /// Chief home of this Mac has that id. Whether a brain holds the home is read now, not cached:
    /// that build may open or quit while this app runs.
    func router(for host: String, fallback: any AgentPaneHostProviding) async -> (any AgentPaneHostProviding)? {
        guard let own = await ownAcpmux(of: host) else { return nil }
        let home = own.home, owner = own.owner
        guard let owned = try? await work.run(.userVisible, mayBlock: .files, { Self.owned(home: home, owner: owner) }) else { return nil }
        return AcpmuxChiefSessionRouter(local: fallback, chief: owned ? own.attaching : own.starting, chiefEnvironment: own.environment,
                                        sessionsHome: own.sessionsHome)
    }

    /// Whether the acpmux of Chief home `host` (`chief:<home id>`) keeps session `session` on disk: a
    /// Chief subagent of this Mac, which a link may open a workspace on (#28877). A miss reads the
    /// Chief root again, as ``router(for:fallback:)`` does.
    public func keeps(session: String, host: String) async -> Bool {
        guard let sessions = await ownAcpmux(of: host)?.sessionsHome else { return false }
        return (try? await work.run(.userVisible, mayBlock: .files) { AcpmuxChiefSessionRouter.keeps(session: session, home: sessions) }) ?? false
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
        guard let found = roots[host] else { return nil }
        let home = ChiefHome(root: found.root, isolated: false), environment = environment
        let owner = ChiefHome(root: found.acpmuxOwner, isolated: false)
        // Resolving acpmux looks at its binaries on disk.
        let resolved: AcpmuxEnvironment?
        do {
            resolved = try await work.run(.userVisible, mayBlock: .files) { environment(owner) }
        } catch {
            return nil // cut short: asked again later
        }
        return OwnAcpmux(home: home, owner: owner, environment: resolved,
                         starting: ownHost(resolved, true), attaching: ownHost(resolved, false))
    }

    /// Whether a live brain host owns the acpmux that runs `home`'s sessions, so a tab only attaches
    /// to it (cx-ebm.54): `home`'s own host, or for a named Chief also its home's (`owner`) host while
    /// that one runs on `<owner>/acpmux`, not on the app's acpmux (its launch mark,
    /// ``ChiefAppAcpmuxMove/readMark(_:)``, names another). It reads the disk.
    nonisolated static func owned(home: ChiefHome, owner: ChiefHome) -> Bool {
        if home.hostRuns { return true }
        guard owner.root != home.root, owner.hostRuns else { return false }
        return ChiefAppAcpmuxMove.readMark(owner).home.map { $0 == owner.acpmuxHome.path } ?? true
    }

    /// Every directory under `parents` by its `chief:<home id>`, each with the named Chiefs' homes
    /// inside it (`<home>/c/<id>`), whose sessions run in that home's acpmux. It reads the disk.
    nonisolated static func homes(in parents: [URL]) -> [String: Found] {
        var homes: [String: Found] = [:]
        for parent in parents {
            for root in directories(in: parent) {
                let id = ChiefHome.tabHost(muxHome: root)
                if homes[id] == nil { homes[id] = Found(root: root, acpmuxOwner: root) }
                // `ChiefHome.brainHome`'s folder: one directory per named Chief.
                for brain in directories(in: root.appendingPathComponent("c", isDirectory: true)) {
                    let id = ChiefHome.tabHost(muxHome: brain)
                    if homes[id] == nil { homes[id] = Found(root: brain, acpmuxOwner: root) }
                }
            }
        }
        return homes
    }

    /// The directories directly under `parent`, hidden ones left out. It reads the disk.
    private nonisolated static func directories(in parent: URL) -> [URL] {
        ((try? FileManager.checked.contentsOfDirectory(atPath: parent.path)) ?? []).compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let root = parent.appendingPathComponent(name, isDirectory: true)
            var directory: ObjCBool = false
            guard FileManager.checked.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { return nil }
            return root
        }
    }
}
