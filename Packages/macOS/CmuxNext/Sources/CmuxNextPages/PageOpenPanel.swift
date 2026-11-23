public import AppKit
public import CmuxNextDesign
public import WebKit

/// Answers a WebKit-hosted page's `<input type="file">` with the system open panel, as a sheet on
/// the page's window (the agent composer's + then Attach files). WebKit shows no chooser for a web
/// view without a UI delegate that implements `runOpenPanelWith`, so a file input does nothing
/// there. The chosen files go back to the page, which reads them as it reads a drop. The panel is
/// the app's one made ahead (`MadeAheadOpenPanel`; an agent pane warms it), so once it is made the
/// click pays only the sheet; a WebKit browser tab's file input takes the same path
/// (`WebFileInputAnswering`). A page hosted in Chromium does not come here (the CEF shim has no
/// file-dialog handler yet). A web view holds its UI delegate weakly: the view that sets this as
/// its delegate keeps it.
@MainActor
public final class PageOpenPanel: NSObject, WKUIDelegate {
    private let openPanel: MadeAheadOpenPanel
    /// Called with the files the person chose, before the page gets them: a pick in the system
    /// panel, which page script can't make (the agent pane records where they came from).
    public var onChosen: (@MainActor ([URL]) -> Void)?

    /// - Parameter openPanel: The app's made-ahead panel (`AppServices.openPanel`).
    public init(openPanel: MadeAheadOpenPanel) {
        self.openPanel = openPanel
    }

    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        #if DEBUG || CMUX_BENCH_HOOKS
        if let answer = debugAnswer {
            debugAnswer = nil
            return completionHandler(answer)
        }
        #endif
        // The one file-input path (WebFileInputAnswering), shared with the WebKit browser tab.
        openPanel.answerFileInput(allowsMultipleSelection: parameters.allowsMultipleSelection,
                                  allowsDirectories: parameters.allowsDirectories,
                                  window: webView.window) { [weak self] urls in
            if let urls, !urls.isEmpty { self?.onChosen?(urls) }
            completionHandler(urls)
        }
    }

    /// A WebKit page's window.print() (the Markdown viewer's Print or Save as PDF): the system print
    /// panel as a sheet on the page's window, as a WebKit browser tab's (`BrowserPagePrint`). Only a
    /// private WKUIDelegate method gets it; without one WebKit prints nothing. The page waits until
    /// the panel ends.
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func printFrame(_ webView: WKWebView, frame: AnyObject?, pdfFirstPageSize: CGSize,
                    completionHandler: @escaping @MainActor () -> Void) {
        guard let window = webView.window, window.attachedSheet == nil else { return completionHandler() }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        // WebKit's print view has no size of its own; without one the panel previews blank pages.
        operation.view?.frame = webView.bounds
        let ended = PagePrintEnded(completionHandler)
        operation.runModal(for: window, delegate: ended,
                           didRun: #selector(PagePrintEnded.printOperationDidRun(_:success:contextInfo:)),
                           contextInfo: Unmanaged.passRetained(ended).toOpaque())
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The files the next file input on a WebKit page takes instead of showing the panel
    /// (`debug.agent_pane set_files`), as a person's pick there gives them.
    public var debugAnswer: [URL]?
    #endif
}

/// The print panel's end for a page's window.print(); kept alive by the operation's context until it runs.
private final class PagePrintEnded: NSObject {
    let done: @MainActor () -> Void

    init(_ done: @escaping @MainActor () -> Void) {
        self.done = done
    }

    @objc(printOperationDidRun:success:contextInfo:)
    func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        done()
        if let contextInfo { Unmanaged<PagePrintEnded>.fromOpaque(contextInfo).release() }
    }
}
