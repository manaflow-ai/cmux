import CmuxNextActions
import CmuxNextCompat
import CmuxNextPalette
import CoreGraphics
import Foundation
import Observation
import CmuxNextWakeups

/// Search Tabs over the App's mirror (plans/cmux-next/tab-search.md): every
/// open tab on every connected machine, in every window, workspace, screen
/// and pane; recency from the location trail; closed tabs from the
/// closed-items log. The rows come from the same mapping `tabs.search`
/// uses (`TabSearchEntries`), over a topology built now. Reads only; every
/// change goes through the owner's existing path (Close Tab, Reopen, the
/// closed-items log).
final class AppTabSearchSource: TabSearchSource {
    private let servicesReference: AppServicesReference
    /// The app's services, which own this; nil (reported) only once they are gone.
    private var services: AppServices? { servicesReference.resolve() }

    private struct Revision: Equatable {
        var tabs: UInt64
        var favicons: Int
    }

    init(services: AppServices) {
        servicesReference = AppServicesReference(services)
    }

    func tabSearchEntries() -> [TabSearchEntry] {
        guard let services else { return [] }
        return TabSearchEntries.entries(ControlSnapshotPublisher.topology(services), TabSearchFactsBuilder.facts(services))
    }

    func focusTab(id: String) {
        guard let services else { return }
        guard services.revealTab(id) else { return services.registry.refuse(TabSearchAppStrings.tabGone) }
    }

    func closeTab(id: String) {
        guard let services else { return }
        guard services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id))) else {
            return services.registry.refuse(TabSearchAppStrings.tabGone)
        }
    }

    func reopenClosedTab(id: String) {
        guard let services else { return }
        HistoryRestorer(services: services).reopen(closedID: id)
    }

    func forgetClosedTab(id: String) {
        guard let services else { return }
        guard let entry = DaemonClosedHistory.entry(DaemonClosedHistory.daemonID(fromHistoryID: id) ?? id, in: services) else { return }
        let closed = DaemonClosedHistory.entries([.tab], in: services)
        for close in TabSearchFactsBuilder.forgotten(entry, among: closed, { ($0.item, $0.daemon.machineID) }) {
            DaemonClosedHistory.delete(close, services: services)
        }
    }

    /// An open browser tab's favicon on this Mac: its live page's, else its record's (never an
    /// incognito tab's record), as the strip and sidebar draw it.
    func favicon(for entry: TabSearchEntry) -> CGImage? {
        guard !entry.isClosed, entry.machine == nil, let services else { return nil }
        let incognito = services.cache.browserTabs.isIncognitoTab(entry.id)
        let record = incognito ? nil : services.machines.local.store.tab(id: entry.id)?.faviconURL
        return services.browserFavicon(key: entry.id, recordFavicon: record)?.cgImage
    }

    /// The closed-tab feed's change signal: it fires after every change to
    /// the mirrored tabs (every machine's structure) and to the daemons'
    /// closed items, and when a favicon lands.
    func changes() -> AsyncStream<Void> {
        guard let services, let changes = services.closedTabs?.changes else { return AsyncStream { $0.finish() } }
        // The revision at subscribe time, read now: a change that lands
        // before the observing task starts is still delivered.
        let favicons = services.favicons
        let subscribed = Revision(tabs: changes.revision, favicons: favicons.revision)
        // A change is a signal, not data: the newest one is enough.
        // `visible`: the open Search Tabs list redraws its rows. A service, not a view: the palette owns the stream.
        let mainWork = services.mainWork
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            var last = subscribed
            let follow = ServiceObservation(.visible, owner: "AppTabSearchSource.changes", on: mainWork) {
                Revision(tabs: changes.revision, favicons: favicons.revision)
            } apply: { revision in
                guard revision != last else { return }
                last = revision
                continuation.yield()
            }
            // The stream ends on any thread; the observation stops on main.
            continuation.onTermination = { _ in
                mainWork.postFromAnyThread(.background, owner: "AppTabSearchSource.changesEnd") { follow.cancel() }
            }
        }
    }
}
