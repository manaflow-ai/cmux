import CmuxNextActions
import CmuxNextCompat
import CmuxNextPalette
import CoreGraphics
import Foundation
import Observation

/// Search Tabs over the App's mirror (plans/cmux-next/tab-search.md): every
/// open tab on every connected machine, in every window, workspace, screen
/// and pane; recency from the location trail; closed tabs from the
/// closed-items log. The rows come from the same mapping `tabs.search`
/// uses (`TabSearchEntries`), over a topology built now. Reads only; every
/// change goes through the owner's existing path (Close Tab, Reopen, the
/// closed-items log).
final class AppTabSearchSource: TabSearchSource {
    private unowned let services: AppServices

    private struct Revision: Equatable {
        var tabs: UInt64
        var favicons: Int
    }

    init(services: AppServices) {
        self.services = services
    }

    func tabSearchEntries() -> [TabSearchEntry] {
        TabSearchEntries.entries(ControlSnapshotPublisher.topology(services), TabSearchFactsBuilder.facts(services))
    }

    func focusTab(id: String) {
        guard services.revealTab(id) else { return services.registry.refuse(TabSearchAppStrings.tabGone) }
    }

    func closeTab(id: String) {
        guard services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id))) else {
            return services.registry.refuse(TabSearchAppStrings.tabGone)
        }
    }

    func reopenClosedTab(id: String) {
        HistoryRestorer(services: services).reopen(closedID: id)
    }

    func forgetClosedTab(id: String) {
        _ = services.closedTabs?.take(id)
    }

    /// An open browser tab's favicon on this Mac: its live page's, else its record's (never an
    /// incognito tab's record), as the strip and sidebar draw it.
    func favicon(for entry: TabSearchEntry) -> CGImage? {
        guard !entry.isClosed, entry.machine == nil else { return nil }
        let incognito = services.cache.browserTabs.isIncognitoTab(entry.id)
        let record = incognito ? nil : services.machines.local.store.tab(id: entry.id)?.faviconURL
        return services.browserFavicon(key: entry.id, recordFavicon: record)?.cgImage
    }

    /// The closed-tab tracker's change signal: it fires after every change
    /// to the tabs it watches (every machine's structure) and to the closed
    /// list, once the list is current, and when a favicon lands.
    func changes() -> AsyncStream<Void> {
        guard let changes = services.closedTabs?.changes else { return AsyncStream { $0.finish() } }
        // The revision at subscribe time, read now: a change that lands
        // before the observing task starts is still delivered.
        let favicons = services.favicons
        let subscribed = Revision(tabs: changes.revision, favicons: favicons.revision)
        // A change is a signal, not data: the newest one is enough.
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { @MainActor in
                var last = subscribed
                for await revision in ObservationStream({ Revision(tabs: changes.revision, favicons: favicons.revision) })
                where revision != last {
                    last = revision
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
