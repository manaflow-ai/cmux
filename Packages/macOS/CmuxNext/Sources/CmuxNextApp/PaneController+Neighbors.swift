import CmuxNextBridge

// Neighbor tabs (`browser.keepNeighborTabsAwake`, plans/cmux-next/neighbor-tabs-DESIGN.md):
// each pane tells hibernation its strip order and shown tab, so the tabs
// beside it stay awake and a nearby switch shows a live page.
extension PaneController {
    /// Reports this pane's tab order, shown tab and presence (off screen: its shown tab wakes no
    /// neighbors, and stays out of the page warm budget).
    func noteNeighbors() {
        guard let hibernation = services.cache.hibernation else { return }
        hibernation.paneDidChange(ObjectIdentifier(self), order: orderedIDs.map(\.rawValue), selected: currentTabKey, visible: isVisible)
    }

    /// The pointer moved onto tab `id` in this pane's strip (nil: off every tab):
    /// a hidden page wakes before the click.
    func noteHover(_ id: StripTabID?) {
        let key = id?.rawValue
        services.cache.hibernation?.noteHover(key == currentTabKey ? nil : key)
    }
}
