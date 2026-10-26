import AppKit
import WebKit

/// File > Print… of a page (`browserPrint`), and a WebKit page's own
/// window.print(). WebKit prints its view through the system print panel, a
/// sheet on the tab's window; Chromium opens its print preview over the page
/// (`cmux_shim_print`), as the page's own window.print() does.
public struct BrowserPagePrint {
    let tab: any BrowserTab

    public init(_ tab: any BrowserTab) {
        self.tab = tab
    }

    /// False when the tab cannot print now (another engine, no page, the
    /// page is in no window, or its window already shows a sheet).
    public func run() -> Bool {
        switch tab {
        case let tab as WebKitTab: printWebKit(tab.webView) {}
        case let tab as CEFTab: printChromium(tab)
        default: false
        }
    }

    /// Opens Chromium's print preview, one-way as `chrome::Print`
    /// (chrome/browser/ui/browser_commands.cc) returns nothing: true once
    /// sent to a page that has a browser. One that closes before Chromium
    /// gets it shows nothing.
    private func printChromium(_ tab: CEFTab) -> Bool {
        guard !tab.isClosed, let browser = tab.browserID, let shim = tab.runtime.shim else { return false }
        _ = shim.printPage(browser)
        return true
    }

    /// Prints the page; a window.print() from a subframe prints the whole
    /// page too. `done` runs when the panel ends, or at once when it cannot
    /// show: a page's window.print() waits until then.
    func printWebKit(_ webView: WKWebView, done: @escaping @MainActor () -> Void) -> Bool {
        guard let window = webView.window, window.attachedSheet == nil else {
            done()
            return false
        }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        // WebKit's print view has no size of its own; without one the panel
        // previews and prints blank pages.
        operation.view?.frame = webView.bounds
        // The job spools off main once the person clicks Print, as WebKit's own
        // WebViewImpl::printOperationWithPrintInfo (UIProcess/mac/WebViewImpl.mm) asks.
        operation.canSpawnSeparateThread = true
        let ended = PrintEnded(done)
        // The sheet form returns once the sheet shows (AppKit: runModalForWindow:delegate:didRunSelector:
        // contextInfo: is document-modal); `ended` runs when the panel ends, so no nested modal loop.
        // SAFETY: contextInfo is nil, so AppKit hands nil back to the didRun method, which never
        // reads it; the selector names that method with the signature AppKit calls.
        unsafe operation.runModal(for: window, delegate: ended, didRun: #selector(PrintEnded.printOperationDidRun(_:success:contextInfo:)),
                                  contextInfo: nil)
        return true
    }
}

/// The print panel's end, for the page's window.print(). The operation does not
/// retain its delegate, so this keeps itself alive until the panel ends.
private final class PrintEnded: NSObject {
    let done: @MainActor () -> Void
    private var keptUntilEnd: PrintEnded?

    init(_ done: @escaping @MainActor () -> Void) {
        self.done = done
        super.init()
        keptUntilEnd = self
    }

    @objc(printOperationDidRun:success:contextInfo:)
    func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo _: UnsafeMutableRawPointer?) {
        done()
        keptUntilEnd = nil
    }
}
