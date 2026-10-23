public import AppKit
import CmuxNextDesign
public import WebKit

/// Answers a page's `<input type="file">` with the system open panel, as a sheet on the page's
/// window (the agent composer's + then Attach files). WebKit shows no chooser for a web view
/// without a UI delegate that implements `runOpenPanelWith`, so a file input does nothing there.
/// The chosen files go back to the page, which reads them as it reads a drop. The panel is the
/// app's one made ahead (`MadeAheadOpenPanel`; an agent pane warms it), so the click pays only
/// the sheet, not the panel's making.
@MainActor
public final class PageOpenPanel: NSObject, WKUIDelegate {
    /// A web view holds its UI delegate weakly; this one is shared and lives as long as the app.
    public static let shared = PageOpenPanel()

    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        // A dead panel (no GUI session) shows no sheet: the page gets a cancel now, not a handler that never comes.
        guard let panel = MadeAheadOpenPanel.shared.panel() else {
            completionHandler(nil)
            return
        }
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
