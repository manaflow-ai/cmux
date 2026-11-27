public import WebKit

extension BrowserReplFrameGate {
    /// An agent's Meta+A, Meta+Z or Shift+Meta+Z that no page handled.
    public enum EditingShortcut: String, Sendable {
        case selectAll, undo, redo

        /// The shortcut behind a Cocoa editing action (`selectAll:`,
        /// `undo:`, `redo:`), or nil for any other action.
        public init?(action: String) {
            guard action.hasSuffix(":") else { return nil }
            self.init(rawValue: String(action.dropLast()))
        }
    }

    /// Runs Select All, Undo or Redo with `document.execCommand` in the
    /// document that holds the keyboard focus, as the Edit menu does there.
    ///
    /// The driver calls this after WebKit reports that no page handled the
    /// key, and the page can navigate a frame or move the focus while that
    /// report is on its way. So, as for the clipboard shortcuts
    /// (``runClipboardShortcut(_:clipboard:in:frames:)``), the gate checks
    /// the focus against the authority, finds the focused frame, and runs
    /// the command there through
    /// ``callAsyncJavaScript(_:arguments:in:frame:contentWorld:userGesture:)``:
    /// the tab is checked again (``checkTab(in:)``) and the document judged
    /// in the command's own script turn, so a document the session's
    /// authority refuses gets no command. Undo and Redo take WebKit's undo
    /// stack, which is the tab's and can hold any frame's edits, so they
    /// run only from an allowed focused document in a tab that shows no
    /// frame the policy blocks.
    ///
    /// - Throws: `blocked` when the focus is in a frame the authority
    ///   refuses, the focused document is one it refuses when the command
    ///   arrives, or (Undo, Redo) the tab shows a frame the policy blocks, `stale` when the focused frame cannot be told or the
    ///   focus moved into a child frame before the command ran, `denied` or
    ///   `cancelled` when the session may no longer use the tab.
    public func runEditingShortcut(
        _ shortcut: EditingShortcut,
        in webView: WKWebView,
        frames: @MainActor () async -> [BrowserReplFrame]
    ) async throws {
        try await runEditingShortcut(shortcut, in: webView, frames: frames, beforeDelivery: nil)
    }

    /// - Parameter beforeDelivery: runs after the focused frame is found and
    ///   before the command is sent (tests stand in for the page navigating
    ///   or moving the focus meanwhile).
    func runEditingShortcut(
        _ shortcut: EditingShortcut,
        in webView: WKWebView,
        frames: @MainActor () async -> [BrowserReplFrame],
        beforeDelivery: (@MainActor () async throws -> Void)?
    ) async throws {
        try checkTab(in: webView)
        let tree = await frames()
        try await checkFocus(in: webView, frames: tree)
        // WebKit's undo stack is the tab's, and nothing tells which
        // document a step belongs to (a blocked frame's `beforeinput` for
        // it cannot cancel it): an Undo run from an allowed document undoes
        // a blocked frame's own last edit just as well. So while the tab
        // shows a frame the policy blocks, Undo and Redo are refused.
        if shortcut != .selectAll, let entry = blocked(tree, in: webView).first {
            throw BrowserReplDriverError(
                code: "blocked",
                message: "The tab shows frame \(entry.frame.shownURL), which the domain policy blocks: \(entry.reason); \(shortcut.rawValue) is refused because the tab's undo stack can hold that frame's edits"
            )
        }
        let leaf = try await focusedFrame(in: webView, tree: tree)
        try await beforeDelivery?()
        let value = try await callAsyncJavaScript(
            Self.editingShortcutSource,
            arguments: ["command": shortcut.rawValue],
            in: webView,
            frame: leaf,
            contentWorld: world
        )
        if (value as? [String: Any])?["moved"] as? Bool == true {
            throw BrowserReplDriverError(code: "stale", message: "The focus moved into a child frame before the \(shortcut.rawValue) ran, so it did nothing; try again")
        }
    }

    /// Runs in the focused frame's document, in the gate's world, in one
    /// turn: the command, unless the focus moved into a child frame.
    private static let editingShortcutSource = """
    let el = document.activeElement;
    while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
    if (\(frameElementTest("el"))) return { moved: true };
    return { ran: document.execCommand(command) };
    """
}
