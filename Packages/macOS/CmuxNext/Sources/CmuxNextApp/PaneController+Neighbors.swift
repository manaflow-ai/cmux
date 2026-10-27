import CmuxNextBridge
import CmuxNextBridgeUI

// Neighbor tabs (`browser.keepNeighborTabsAwake`, plans/cmux-next/neighbor-tabs-DESIGN.md):
// each pane tells hibernation its strip order and shown tab, so the tabs
// beside it stay awake and a nearby switch shows a live page.
extension PaneController {
    /// Reports this pane's tab order and shown tab (none while the pane is off screen).
    func noteNeighbors() {
        guard let hibernation = services.cache.hibernation else { return }
        hibernation.paneDidChange(ObjectIdentifier(self), order: orderedIDs.map(\.rawValue), selected: isVisible ? currentTabKey : nil)
    }

    /// The pointer moved onto tab `id` in this pane's strip (nil: off every tab):
    /// a hidden page wakes before the click.
    func noteHover(_ id: StripTabID?) {
        let key = id?.rawValue
        services.cache.hibernation?.noteHover(key == currentTabKey ? nil : key)
    }
}
