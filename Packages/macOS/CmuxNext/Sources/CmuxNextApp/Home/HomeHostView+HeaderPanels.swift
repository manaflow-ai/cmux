import CmuxNextCompat
import CmuxNextHome

extension HomeHostView {
    /// What this Home's header toggles read and act on: its window and its conversation's Chief.
    var headerPanelContext: HomeHeaderPanelContext {
        HomeHeaderPanelContext(services: control.services, window: window.flatMap { control.services.windows.owner(of: $0) },
                               isChief: isChief, chief: control.named, server: control.server?.machineID)
    }

    /// The header's top-right toggles (``HomeHeaderPanels``) follow their panels while this Home
    /// is in a window: one observation of what they read (the tree's page tabs, the window's
    /// right sidebar, the shortcuts, the Debug Settings toggle), no polling. Restarted when the
    /// view changes windows (`viewDidMoveToWindow`) or the conversation becomes (or stops being) a Chief's.
    func watchHeaderPanels() {
        headerPanelsWatch?.cancel()
        headerPanelsWatch = nil
        guard window != nil else { return transcript.setHeaderPanels([]) }
        let context = headerPanelContext
        // task-owner: lives while this view is in its window (cancelled on the next move and in deinit); event-driven (Observation)
        headerPanelsWatch = Task { [weak self] in
            for await items in ObservationStream({ HomeHeaderPanels.items(context) }) {
                self?.transcript.setHeaderPanels(items)
            }
        }
    }
}
