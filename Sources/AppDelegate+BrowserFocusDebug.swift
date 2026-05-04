import AppKit
import Foundation

#if DEBUG
extension AppDelegate {
    func browserLogOmnibarFocusAppKey(event: NSEvent) {
        BrowserOmnibarFocusLatencyTracker.shared.markAppKey(
            event: event,
            firstResponder: NSApp.keyWindow?.firstResponder,
            addressBarPanelId: focusedBrowserAddressBarPanelId()
        )
    }

    func browserFocusStateSnapshot() -> String {
        let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let focused = tabManager?.selectedWorkspace?.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let addressBar = focusedBrowserAddressBarPanelId().map { String($0.uuidString.prefix(5)) } ?? "nil"
        let totalPanels = tabManager?.selectedWorkspace?.panels.count ?? -1
        let browserPanels = tabManager?.selectedWorkspace?.panels.values.reduce(0) { count, panel in
            count + (panel is BrowserPanel ? 1 : 0)
        } ?? -1
        let keyWindow = NSApp.keyWindow?.windowNumber ?? -1
        let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "selected=\(selected) focused=\(focused) addr=\(addressBar) panels=\(totalPanels) browsers=\(browserPanels) keyWin=\(keyWindow) fr=\(firstResponderType)"
    }

    func browserFocusPanelCounts(for panel: BrowserPanel) -> (total: Int, browsers: Int) {
        guard let workspace = tabManager?.tabs.first(where: { $0.id == panel.workspaceId }) else {
            return (-1, -1)
        }
        let browserCount = workspace.panels.values.reduce(0) { count, panel in
            count + (panel is BrowserPanel ? 1 : 0)
        }
        return (workspace.panels.count, browserCount)
    }
}
#endif
