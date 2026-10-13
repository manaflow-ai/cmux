import Foundation
import WebKit

/// WebKit's list with the entries saved before a relaunch around it (`WebKitRestoredSessionHost`).
extension WebKitTab: BrowserBackForwardListing, BrowserSessionRestoring {
    public func navigationList() -> BrowserNavigationList? { restored.navigationList() }
    @discardableResult
    public func goToEntry(offset: Int) -> Bool { restored.goToEntry(offset: offset) }
    public func restoreSession(_ entries: [BrowserSavedEntry], current: Int) { restored.restore(entries, current: current) }
    /// Scrolls the shown page to `y` once it loads (a page restored from WebKit's own state).
    public func scrollOnLoad(to y: Double) { restored.scrollOnLoad(to: y) }
    public func currentScrollY() async -> Double? { await WebKitRestoredSessionHost(tab: self).currentScrollY() }
    public func savedSession(measuringScroll: Bool) async -> BrowserSavedSession? {
        await restored.savedSession(measuringScroll: measuringScroll)
    }
}
