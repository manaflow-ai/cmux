import CmuxNextActions
import CmuxNextPalette
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

    /// The closed-tab tracker's change signal: it fires after every change
    /// to the tabs it watches (every machine's structure) and to the closed
    /// list, once the list is current.
    func changes() -> AsyncStream<Void> {
        guard let changes = services.closedTabs?.changes else { return AsyncStream { $0.finish() } }
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                var first = true
                for await _ in Observations({ changes.revision }) {
                    if first {
                        first = false
                        continue
                    }
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
