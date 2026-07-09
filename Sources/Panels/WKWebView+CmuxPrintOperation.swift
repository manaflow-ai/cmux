import AppKit
import WebKit

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
