import CmuxNextDaemon
public import Observation

/// Which daemon lists each tab, by durable tab id or tab resource id, over every machine the app
/// shows (plans/cmux-next/chrome-parity/p06-scheduler.md, task 051): finding a tab's machine is one
/// dictionary read, whatever the number of machines and tabs.
///
/// Each tracked daemon's store reports the keys its index gains or drops (``StoreTabKeys``), so the
/// index costs the tabs a change names. Chromium finds a tab's owner the same way, from a link the
/// tab's own attach and detach keep (`tabs::TabInterface::GetFromContents`,
/// chrome/browser/ui/tabs/public/tab_interface.h), not by walking every window.
///
/// A tracked caller (a wait for a tab to appear) that finds nothing reads ``revision``, so it hears
/// a tab listed on any machine; one that finds a tab reads that daemon's store, which tells it when
/// the tab moves or goes.
@Observable public final class MachineTabIndex {
    /// The daemons listing each key, in the order they listed it: one, except for the moment a tab
    /// moves between machines.
    @ObservationIgnored private var holders: [String: [ObjectIdentifier]] = [:]
    @ObservationIgnored private var tracked: [ObjectIdentifier: DaemonService] = [:]
    /// Bumped each time a key is listed by a daemon.
    public private(set) var revision: UInt64 = 0
    /// Lookups answered since creation (tests: one locate is one lookup, at any scale).
    @ObservationIgnored public private(set) var lookups = 0

    public init() {}

    /// Follows `daemon`'s tabs until ``forget(_:)``; a second call does nothing.
    public func track(_ daemon: DaemonService) {
        let id = ObjectIdentifier(daemon)
        guard tracked.updateValue(daemon, forKey: id) == nil else { return }
        let keys = daemon.store.tabKeys
        keys.onChange = { [weak self] key, change in self?.note(key, change, by: id) }
        for key in keys.listed { note(key, .listed, by: id) }
    }

    /// Stops following `daemon` (its machine left the app) and drops its tabs.
    public func forget(_ daemon: DaemonService) {
        let id = ObjectIdentifier(daemon)
        guard tracked.removeValue(forKey: id) != nil else { return }
        let keys = daemon.store.tabKeys
        keys.onChange = nil
        for key in keys.listed { note(key, .dropped, by: id) }
    }

    /// The daemon whose store lists a tab with durable id or tab resource id `key`.
    public func daemon(holdingTab key: String) -> DaemonService? {
        lookups &+= 1
        guard let holder = holders[key]?.first else {
            _ = revision
            return nil
        }
        return tracked[holder]
    }

    private func note(_ key: String, _ change: StoreTabKeys.Change, by daemon: ObjectIdentifier) {
        switch change {
        case .listed:
            holders[key, default: []].append(daemon)
            revision &+= 1
        case .dropped:
            guard var list = holders[key], let at = list.firstIndex(of: daemon) else { return }
            list.remove(at: at)
            holders[key] = list.isEmpty ? nil : list
        }
    }
}
