import CmuxNextDaemon
import CmuxNextBridge
import CmuxNextTabs

extension WindowController {
    /// This window's controller of `pane`, when this window shows it. Not
    /// `AppServices.paneController(for:)`, which returns the first window's.
    func paneController(for pane: PaneModel) -> PaneController? {
        guard let found = content?.pane(for: pane.handle), found.pane === pane else { return nil }
        return found
    }

    /// The one way to select `tab` of `pane` in this window without a focus
    /// intent (plans/cmux-next/pane-active-tab-DESIGN.md S3): records it in
    /// this window's selection memory and, when this window shows the pane,
    /// shows it there now, so the memory, the strip and the content never
    /// name different tabs. A tab the pane does not list yet is selected
    /// once the daemon reports it. Never moves focus.
    func selectTab(_ tab: String, in pane: PaneModel) {
        state.selection.select(tab, in: pane.id)
        guard let controller = paneController(for: pane) else { return }
        if controller.stripModel.tab(StripTabID(tab)) != nil {
            controller.applySelection(StripTabID(tab))
        } else {
            controller.selectWhenReported(tab: tab)
        }
    }
}
