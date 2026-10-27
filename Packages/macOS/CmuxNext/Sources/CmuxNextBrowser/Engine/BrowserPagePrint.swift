import AppKit
import PDFKit
import WebKit

/// File > Print… of a page (`browserPrint`), and a WebKit page's own
/// window.print(). WebKit prints its view through the system print panel, a
/// sheet on the tab's window; Chromium opens its print preview over the page
/// (`cmux_shim_print`), as the page's own window.print() does. In host mode
/// with feature `chromiumHostPrint`, the Chromium Host prints the page to PDF
/// and the same panel shows that PDF on the tab's window
/// (``ChromiumHostPagePrints``, task p01-process-065): Chromium's preview would
/// be a window of the host.
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
    /// gets it shows nothing. A host page printed through cmux asks the host
    /// for its PDF: true once asked, false when the tab's window shows a sheet
    /// or the host cannot print.
    private func printChromium(_ tab: CEFTab) -> Bool {
        guard !tab.isClosed, let browser = tab.browserID, let shim = tab.runtime.shim else { return false }
        if let prints = tab.runtime.hostStart?.pagePrints {
            guard let window = tab.contentView.window else { return false }
            return prints.print(browser, on: window, runtime: tab.runtime)
        }
        _ = shim.printPage(browser)
        return true
    }

    /// Shows the print panel on `document` (a page the Chromium Host printed
    /// to PDF at the panel's paper, so it prints at its own size), a sheet on
    /// `window` as for a WebKit page. `done` runs when the panel ends; false,
    /// and `done` never runs, when it cannot show.
    static func printPDF(_ document: PDFDocument, on window: NSWindow, done: @escaping @MainActor () -> Void) -> Bool {
        guard window.attachedSheet == nil,
              let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleNone, autoRotate: true)
        else { return false }
        // Spools off main once the person clicks Print, as for a WebKit page.
        operation.canSpawnSeparateThread = true
        runSheet(operation, on: window, done: done)
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
        Self.runSheet(operation, on: window, done: done)
        return true
    }

    /// Runs `operation`'s panel as a sheet on `window`; `done` runs when it ends.
    private static func runSheet(_ operation: NSPrintOperation, on window: NSWindow, done: @escaping @MainActor () -> Void) {
        let ended = PrintEnded(done)
        // The sheet form returns once the sheet shows (AppKit: runModalForWindow:delegate:didRunSelector:
        // contextInfo: is document-modal); `ended` runs when the panel ends, so no nested modal loop.
        // SAFETY: contextInfo is nil, so AppKit hands nil back to the didRun method, which never
        // reads it; the selector names that method with the signature AppKit calls.
        unsafe operation.runModal(for: window, delegate: ended, didRun: #selector(PrintEnded.printOperationDidRun(_:success:contextInfo:)),
                                  contextInfo: nil)
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
