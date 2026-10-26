import AppKit
import CmuxNextFeatures
import CmuxNextPages

extension AppServices {
    /// The app's one preload slot (p13-webui.md 3.D), made here only and installed on `webUI`: New
    /// Tab (``NewTabPreload``) and Settings, History and Cloud (``PagePreloads``) both take it from
    /// here, so it has one park state whichever asks first. Rendered-parked until spike 090 records
    /// its choice.
    var preloadSlot: PagePreloadSlot {
        if let slot = webUI.preload { return slot }
        let slot = PagePreloadSlot(parkState: .renderedParked, deadlines: mainDeadlines)
        webUI.preload = slot
        return slot
    }

    /// Settings, History and Cloud through the one preload slot (feature `pagePreload`): parked in
    /// the active window at its focused pane's tab size, and no Settings preload while
    /// ``SettingsWindowService`` keeps a page that its next open shows again.
    func makePagePreloads() -> PagePreloads {
        PagePreloads(
            webUI: webUI, slot: preloadSlot, deadlines: mainDeadlines, input: inputTap,
            isEnabled: { [weak self] in self?.features.isEnabled(.pagePreload) == true },
            target: { [weak self] in
                guard let controller = self?.windows.active, let content = controller.window?.contentView else { return nil }
                return (content, controller.focusedPane.map(NewTabPreload.newTabContentSize(in:)) ?? content.bounds.size)
            },
            keepsView: { [weak self] page in page == .settings && self?.settingsWindow.keepsPage == true })
    }
}
