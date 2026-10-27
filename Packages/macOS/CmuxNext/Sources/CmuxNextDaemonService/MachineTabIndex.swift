public import CmuxNextDaemon
public import Observation

/// Which daemon lists each tab, by durable tab id or tab resource id, over every machine the app
/// shows (plans/cmux-next/chrome-parity/p06-scheduler.md, task 051): finding a tab and its pane is
/// one dictionary read and one read of that daemon's store, whatever the number of machines and tabs.
///
/// Each tracked daemon's store reports the net key changes of each apply (``StoreTabKeys``), so the
/// index costs the tabs a change names. Chromium finds a tab's owner the same way, from a link the
/// tab's own attach and detach keep (`tabs::TabInterface::GetFromContents`,
/// chrome/browser/ui/tabs/public/tab_interface.h), not by walking every window.
///
/// Two machines can list the same key (a tab moving between them, or a fallback id such as
/// `surface:1` on both): the machine first in the registry's order wins (``Rank``), as the walk of
/// every machine did. Every lookup reads ``revision``, which moves when a key appears or goes on any
/// machine and when a machine is tracked or forgotten, so a tracked caller hears each change that
/// can change its answer.
@Observable public final class MachineTabIndex {
    /// A machine's place in the registry's order: local, then Cloud, then SSH, then servers, each
    /// in the order they were added.
    public enum Tier: Int, Sendable {
        case local, cloud, ssh, server
    }

    private struct Rank {
        let tier: Tier
        /// Order of ``track(_:as:)`` calls: within a tier, the order the registry added them.
        let sequence: UInt64

        func precedes(_ other: Rank) -> Bool {
            tier == other.tier ? sequence < other.sequence : tier.rawValue < other.tier.rawValue
        }
    }

    private struct Tracked {
        let daemon: DaemonService
        let rank: Rank
    }

    /// The daemons listing each key, first in rank first: one, except for a key two machines list.
    @ObservationIgnored private var holders: [String: [ObjectIdentifier]] = [:]
    @ObservationIgnored private var tracked: [ObjectIdentifier: Tracked] = [:]
    @ObservationIgnored private var nextSequence: UInt64 = 0
    /// Moves when a key is listed or dropped on a tracked machine, and when a machine is tracked or
    /// forgotten: at most once per store apply or machine change.
    public private(set) var revision: UInt64 = 0

    public init() {}

    /// Follows `daemon`'s tabs until ``forget(_:)``, ranked by `tier`; a second call does nothing.
    public func track(_ daemon: DaemonService, as tier: Tier) {
        let id = ObjectIdentifier(daemon)
        guard tracked[id] == nil else { return }
        tracked[id] = Tracked(daemon: daemon, rank: Rank(tier: tier, sequence: nextSequence))
        nextSequence &+= 1
        let keys = daemon.store.tabKeys
        keys.listen(self) { [weak self] changes in self?.apply(changes, by: id) }
        for key in keys.listed { list(key, by: id) }
        revision &+= 1
    }

    /// Stops following `daemon` (its machine left the app) and drops its tabs.
    public func forget(_ daemon: DaemonService) {
        let id = ObjectIdentifier(daemon)
        guard tracked[id] != nil else { return }
        let keys = daemon.store.tabKeys
        keys.stopListening(self)
        for key in keys.listed { drop(key, by: id) }
        tracked[id] = nil
        revision &+= 1
    }

    /// The daemon whose store lists a tab with durable id or tab resource id `key`; the first in the
    /// registry's order when several do.
    public func daemon(holdingTab key: String) -> DaemonService? {
        _ = revision
        guard let holder = holders[key]?.first else { return nil }
        return tracked[holder]?.daemon
    }

    /// The tab with durable id or tab resource id `key` and the pane holding it, on the machine that
    /// lists it (`AppServices.locateTab`).
    public func locate(_ key: String) -> (TabModel, PaneModel)? {
        guard let store = daemon(holdingTab: key)?.store, let tab = store.tab(idOrResource: key),
              let pane = store.pane(holding: tab) else { return nil }
        return (tab, pane)
    }

    private func apply(_ changes: [String: StoreTabKeys.Change], by daemon: ObjectIdentifier) {
        for (key, change) in changes {
            switch change {
            case .listed: list(key, by: daemon)
            case .dropped: drop(key, by: daemon)
            }
        }
        revision &+= 1
    }

    private func list(_ key: String, by daemon: ObjectIdentifier) {
        guard let rank = tracked[daemon]?.rank else { return }
        var list = holders[key, default: []]
        guard !list.contains(daemon) else { return }
        let at = list.firstIndex { other in tracked[other].map { rank.precedes($0.rank) } ?? true } ?? list.endIndex
        list.insert(daemon, at: at)
        holders[key] = list
    }

    private func drop(_ key: String, by daemon: ObjectIdentifier) {
        guard var list = holders[key], let at = list.firstIndex(of: daemon) else { return }
        list.remove(at: at)
        holders[key] = list.isEmpty ? nil : list
    }
}
