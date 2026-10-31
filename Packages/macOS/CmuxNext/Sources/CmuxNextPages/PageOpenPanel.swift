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

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The files the next file input on a WebKit page takes instead of showing the panel
    /// (`debug.agent_pane set_files`), as a person's pick there gives them.
    public var debugAnswer: [URL]?
    #endif
}
