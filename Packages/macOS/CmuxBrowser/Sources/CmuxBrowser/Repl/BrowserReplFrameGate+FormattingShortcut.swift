public import WebKit

extension BrowserReplFrameGate {
    /// An agent's Meta+B, Meta+I or Meta+U that no page handled.
    public enum FormattingShortcut: String, Sendable {
        case bold, italic, underline
    }

    /// Formats the selection of the main frame's focused editable element
    /// (or of a `designMode` document) with `document.execCommand`, as
    /// Chrome's editor does for Command+B/I/U; the page sees its usual
    /// `beforeinput` and `input`.
    ///
    /// The driver calls this after WebKit reports that no page handled the
    /// key, and the page can navigate the main frame, or the user move the
    /// tab, while that report is on its way. So the command runs through
    /// ``callAsyncJavaScript(_:arguments:in:frame:contentWorld:userGesture:)``:
    /// the gate checks the tab again (``checkTab(in:)``) and judges the
    /// document the command runs in, in the same script turn, so a page the
    /// session's authority refuses is never formatted.
    ///
    /// - Returns: whether the command ran (false when nothing editable has
    ///   the focus).
    /// - Throws: `blocked` when the main frame shows a page the authority
    ///   refuses, `stale` when it keeps navigating, `denied` or `cancelled`
    ///   when the session may no longer use the tab.
    @discardableResult
    public func runFormattingShortcut(_ shortcut: FormattingShortcut, in webView: WKWebView) async throws -> Bool {
        try await runFormattingShortcut(shortcut, in: webView, beforeDelivery: nil)
    }

    /// - Parameter beforeDelivery: runs before the command is sent (tests
    ///   stand in for the page navigating meanwhile).
    func runFormattingShortcut(
        _ shortcut: FormattingShortcut,
        in webView: WKWebView,
        beforeDelivery: (@MainActor () async throws -> Void)?
    ) async throws -> Bool {
        // The main frame as the driver names it without a tree read; the
        // gate judges the document it shows when the script arrives.
        let mainFrame = BrowserReplFrame(
            frameID: "main",
            parentFrameID: nil,
            indexInParent: 0,
            info: nil,
            url: webView.url?.absoluteString ?? "",
            name: "",
            crossOrigin: false
        )
        try await beforeDelivery?()
        do {
            let value = try await callAsyncJavaScript(
                Self.formattingShortcutSource,
                arguments: ["command": shortcut.rawValue],
                in: webView,
                frame: mainFrame,
                contentWorld: .page
            )
            return value as? Bool == true
        } catch let error as BrowserReplDriverError {
            throw error
        } catch {
            // The page's own script threw (it runs in the page world, where
            // the page controls `execCommand`): nothing was formatted.
            return false
        }
    }

    private static let formattingShortcutSource = """
    const el = document.activeElement;
    if (!(document.designMode === "on" || (el && el.isContentEditable))) return false;
    return document.execCommand(command);
    """
}
