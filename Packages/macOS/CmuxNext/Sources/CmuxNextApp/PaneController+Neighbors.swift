import CmuxNextBridge

// Neighbor tabs (`browser.keepNeighborTabsAwake`, plans/cmux-next/neighbor-tabs-DESIGN.md):
// each pane tells hibernation its strip order and shown tab, so the tabs
// beside it stay awake and a nearby switch shows a live page.
extension PaneController {
    /// Reports this pane's tab order and shown tab (none while the pane is off screen).
    func noteNeighbors() {
        guard let hibernation = services.cache.hibernation else { return }
        hibernation.paneDidChange(ObjectIdentifier(self), order: orderedIDs.map(\.rawValue), selected: isVisible ? currentTabKey : nil)
    }

    /// The pointer moved onto tab `id` in this pane's strip (nil: off every tab): after the hover dwell
    /// (`HoverWakeIntent.dwell`, 100 ms) a hidden page wakes, and a tab with no content yet loads.
    func noteHover(_ id: StripTabID?) {
        let key = id?.rawValue == currentTabKey ? nil : id?.rawValue
        services.cache.hibernation?.noteHover(key)
        hoverLoad.note(key.map { .tab($0) })
    }

    /// The pointer rested on tab `key`: makes its content hidden when it has none yet (a tab restored at launch or
    /// opened in the background), so its click shows it ready ("just hovering on tab should immediately load the tab").
    func loadOnHover(_ key: String) {
        guard key != currentTabKey, existingContent(for: key) == nil, let tab = pane.tabs.first(where: { $0.id == key }), tab.loadsAheadOnHover else { return }
        if tab.kind != .conversation { _ = content(for: key) } else if services.launchReveal.isReady(.pane) { _ = services.agentTabs.view(for: key, machine: daemon.machineID) }
    }
}
