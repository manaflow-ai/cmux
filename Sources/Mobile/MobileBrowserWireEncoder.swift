import CMUXMobileCore
import Foundation

@MainActor
struct MobileBrowserWireEncoder {
    func descriptor(panel: BrowserPanel) -> MobileBrowserPanelDescriptor {
        let size = panel.webView.bounds.size
        let title = panel.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return MobileBrowserPanelDescriptor(
            panelID: panel.id.uuidString,
            workspaceID: panel.workspaceId.uuidString,
            url: (panel.currentURL ?? panel.webView.url)?.absoluteString,
            title: title.isEmpty ? nil : title,
            pageWidth: max(0, Double(size.width)),
            pageHeight: max(0, Double(size.height)),
            canGoBack: panel.canGoBack,
            canGoForward: panel.canGoForward,
            isLoading: panel.isLoading,
            pendingDialog: panel.mobileBrowserDialogBroker.currentDialog
        )
    }

    func state(panel: BrowserPanel, editableFocused: Bool) -> MobileBrowserStateEvent {
        let title = panel.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return MobileBrowserStateEvent(
            panelID: panel.id.uuidString,
            url: (panel.currentURL ?? panel.webView.url)?.absoluteString,
            title: title.isEmpty ? nil : title,
            canGoBack: panel.canGoBack,
            canGoForward: panel.canGoForward,
            isLoading: panel.isLoading,
            progress: panel.estimatedProgress,
            editableFocused: editableFocused
        )
    }

    func object<Value: Encodable>(_ value: Value) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
