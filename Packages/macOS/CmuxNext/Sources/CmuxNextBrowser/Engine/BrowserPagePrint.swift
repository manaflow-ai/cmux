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
        case let tab as CEFTab: tab.browserID.map { tab.runtime.shim?.printPage($0) == 1 } ?? false
        default: false
        }
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
        let ended = PrintEnded(done)
        operation.runModal(for: window, delegate: ended, didRun: #selector(PrintEnded.printOperationDidRun(_:success:contextInfo:)),
                           contextInfo: Unmanaged.passRetained(ended).toOpaque())
        return true
    }
}

/// The print panel's end, for the page's window.print(); kept alive by the
/// operation's context until it runs.
private final class PrintEnded: NSObject {
    let done: @MainActor () -> Void

    init(_ done: @escaping @MainActor () -> Void) {
        self.done = done
    }

    @objc(printOperationDidRun:success:contextInfo:)
    func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        done()
        if let contextInfo { Unmanaged<PrintEnded>.fromOpaque(contextInfo).release() }
    }
}
