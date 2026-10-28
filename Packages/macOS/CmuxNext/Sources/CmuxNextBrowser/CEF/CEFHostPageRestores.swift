import Foundation

/// The pages of a crashed Chromium Host that come back on the next host, by tab (``CEFRuntime/restorePagesOnNextHost(_:reading:)``).
final class CEFHostPageRestores {
    /// Where a tab's restore is.
    enum Phase: Equatable {
        /// Its saved navigation is read and the next host starts (the restore of host end `generation`): no browser
        /// is made for it until then.
        case reading(UInt64)
        /// Hidden: its next browser restores its saved navigation, or loads its address, once it shows.
        case waitsForShow
    }

    private struct Entry {
        weak var tab: CEFTab?
        var phase: Phase
    }

    private var entries: [BrowserTabID: Entry] = [:]
    private var generation: UInt64 = 0

    /// `tab`'s restore, nil when it has none.
    func phase(of tab: CEFTab) -> Phase? {
        guard let entry = entries[tab.id], entry.tab === tab else { return nil }
        return entry.phase
    }

    /// `tab` waits for its saved navigation and the next host: ``CEFPaneHost/ensureCreated(_:machineProxyApplied:)`` makes no browser for it.
    func blocksCreation(of tab: CEFTab) -> Bool {
        if case .reading? = phase(of: tab) { true } else { false }
    }

    /// A host ended with every page waiting here: their restores end, and none comes back on its own.
    func endAll() {
        entries = [:]
    }

    /// A host ended within its budget: earlier restores end (their pages went with it too) and a new one starts for
    /// its pages. Returns the new restore's generation.
    func begin() -> UInt64 {
        endAll()
        generation &+= 1
        return generation
    }

    /// Sets `tab`'s restore; nil ends it.
    func set(_ phase: Phase?, for tab: CEFTab) {
        guard let phase else {
            if entries[tab.id]?.tab === tab { entries[tab.id] = nil }
            return
        }
        entries[tab.id] = Entry(tab: tab, phase: phase)
    }
}
