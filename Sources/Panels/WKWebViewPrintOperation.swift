import AppKit
import WebKit

// Restored during the main merge: this WKWebView print helper originally lived
// in Sources/Panels/BrowserNavigationDelegate.swift on main. That file was
// removed as a duplicate of the app-target's own `BrowserNavigationDelegate`
// class, but this extension (used by BrowserPanel+PDFDocumentActions) was unique
// to it, so it is preserved here.
extension WKWebView {
    @MainActor
    func cmuxRunPrintOperation() {
        guard #available(macOS 11.0, *) else { return }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let operation = printOperation(with: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
