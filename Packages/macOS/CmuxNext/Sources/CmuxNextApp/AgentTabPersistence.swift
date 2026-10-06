import CmuxNextDaemon
import Observation

/// Agent chat tabs across quit and relaunch (R138, plans/cmux-next/quit-persistence.md G4).
/// cmux-tui has no agent tab kind yet, so each pane's agent tabs live in the daemon's window
/// document; their acpmux sessions are durable in acpmux, so a reopened tab reattaches to the
/// same session and shows the transcript and any running turn.
@MainActor
enum AgentTabPersistence {
    /// Once the daemon's tree loads: reopens the recorded agent tabs, then records every change.
    static func start(_ services: AppServices) {
        // The window state store exists only once the daemon connects, which
        // is after launch (DaemonService sets it before the store loads):
        // read it when the tree has loaded. Reading it here at launch found
        // nil, so no agent tab was ever recorded (subagent tabs of the Home
        // Chief, 2026-10-06).
        let store = services.daemon.store
        // task-owner: one-shot, ends after the first load
        Task {
            for await loaded in Observations({ store.isLoaded }) where loaded {
                guard let windowState = services.daemon.windowState else { return }
                let document = (try? await windowState.load()) ?? WindowStateDocument()
                let tabs = services.agentTabs
                // A pane gone by now (closed while the app was quit) drops its tabs when the live
                // tree arrives (AgentTabStore.closeGonePanes), which also clears its record.
                for (pane, records) in document.agentTabs { tabs.restore(records, in: pane, of: store) }
                // Panes already on screen list the tabs now; the window's remembered selection
                // (WindowRecord.selectedTabs) picks a restored agent tab again by its id.
                for controller in services.windows.controllers {
                    for pane in document.agentTabs.keys { controller.content?.paneController(key: pane)?.resyncStrip() }
                }
                tabs.onRecordsChanged = { pane, records in
                    // task-owner: one compare-and-swap write per change, serialized by the store actor
                    Task {
                        try? await windowState.update { document in
                            document.agentTabs[pane] = records.isEmpty ? nil : records
                        }
                    }
                }
                return
            }
        }
    }
}
