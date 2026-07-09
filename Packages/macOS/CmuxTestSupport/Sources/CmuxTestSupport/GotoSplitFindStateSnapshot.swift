#if DEBUG
public import Foundation

/// A pure snapshot of the goto-split find-state capture fields for one
/// workspace, captured by the app-side `GotoSplitUITestRecorder` on the main
/// actor and formatted into the `[String: String]` capture object the
/// `CMUX_UI_TEST_GOTO_SPLIT_*` XCUITest scenarios read back.
///
/// Only *reading* the live state is app-coupled: the focused pane / panel, the
/// per-panel `searchState` find needles, and the first-responder terminal
/// surface are all read from `Workspace` / `Bonsplit` / AppKit, which a lower
/// package cannot reference. Turning those facts into the exact capture-field
/// dictionary is pure value logic, so it moves here unchanged while the live
/// reads stay behind ``GotoSplitUITestRecorder`` app-side. ``captureFields`` is
/// byte-identical to the dictionary the legacy `findStateSnapshot(for:)` built.
///
/// Isolation: a `Sendable` value with no references; the recorder fills one in
/// per capture turn and reads ``captureFields``.
public struct GotoSplitFindStateSnapshot: Sendable {
    /// The focused panel within the workspace, carrying the resolved find needle
    /// for terminal/browser panels. Mirrors the legacy focused-panel branch that
    /// set `focusedPanelId` / `focusedPanelKind` / `focusedTerminalFindNeedle` /
    /// `focusedBrowserFindNeedle`.
    public enum FocusedPanel: Sendable {
        /// No focused panel (`focusedPanelKind` == `"none"`).
        case none
        /// A focused terminal panel and its current find needle (`""` when no
        /// search is active).
        case terminal(panelId: UUID, findNeedle: String)
        /// A focused browser panel and its current find needle (`""` when no
        /// search is active).
        case browser(panelId: UUID, findNeedle: String)
        /// A focused panel that is neither a terminal nor a browser panel
        /// (`focusedPanelKind` == `"other"`).
        case other(panelId: UUID)
    }

    /// The first terminal panel with an active find session, if any. Drives the
    /// `terminalFind*` capture fields.
    public struct TerminalFind: Sendable {
        /// The panel id of the terminal with an active find session.
        public var panelId: UUID
        /// The active find needle.
        public var needle: String

        /// Creates a terminal find snapshot.
        public init(panelId: UUID, needle: String) {
            self.panelId = panelId
            self.needle = needle
        }
    }

    /// The first browser panel with an active find session, if any. Drives the
    /// `browserFind*` capture fields.
    public struct BrowserFind: Sendable {
        /// The panel id of the browser with an active find session.
        public var panelId: UUID
        /// The active find needle.
        public var needle: String
        /// The zero-based selected match index, if any (formatted one-based).
        public var selected: UInt?
        /// The total match count, if any.
        public var total: UInt?

        /// Creates a browser find snapshot.
        public init(panelId: UUID, needle: String, selected: UInt?, total: UInt?) {
            self.panelId = panelId
            self.needle = needle
            self.selected = selected
            self.total = total
        }
    }

    /// The focused Bonsplit pane id rendered with `description`, or `""`.
    public var focusedPaneId: String

    /// The focused panel and its find needle.
    public var focusedPanel: FocusedPanel

    /// The first terminal panel with an active find session, if any.
    public var terminalFind: TerminalFind?

    /// The first browser panel with an active find session, if any.
    public var browserFind: BrowserFind?

    /// The id of the terminal surface owning the current first responder, if
    /// any.
    public var firstResponderTerminalPanelId: UUID?

    /// Creates a find-state snapshot from the app-side reads.
    public init(
        focusedPaneId: String,
        focusedPanel: FocusedPanel,
        terminalFind: TerminalFind?,
        browserFind: BrowserFind?,
        firstResponderTerminalPanelId: UUID?
    ) {
        self.focusedPaneId = focusedPaneId
        self.focusedPanel = focusedPanel
        self.terminalFind = terminalFind
        self.browserFind = browserFind
        self.firstResponderTerminalPanelId = firstResponderTerminalPanelId
    }

    /// The capture-field object, byte-identical to the dictionary the legacy
    /// `findStateSnapshot(for:)` produced (before the app-side responder-snapshot
    /// merge).
    public var captureFields: [String: String] {
        var updates: [String: String] = [
            "focusedPaneId": focusedPaneId
        ]

        switch focusedPanel {
        case .none:
            updates["focusedPanelId"] = ""
            updates["focusedPanelKind"] = "none"
            updates["focusedTerminalFindNeedle"] = ""
            updates["focusedBrowserFindNeedle"] = ""
        case let .terminal(panelId, findNeedle):
            updates["focusedPanelId"] = panelId.uuidString
            updates["focusedPanelKind"] = "terminal"
            updates["focusedTerminalFindNeedle"] = findNeedle
            updates["focusedBrowserFindNeedle"] = ""
        case let .browser(panelId, findNeedle):
            updates["focusedPanelId"] = panelId.uuidString
            updates["focusedPanelKind"] = "browser"
            updates["focusedBrowserFindNeedle"] = findNeedle
            updates["focusedTerminalFindNeedle"] = ""
        case let .other(panelId):
            updates["focusedPanelId"] = panelId.uuidString
            updates["focusedPanelKind"] = "other"
            updates["focusedTerminalFindNeedle"] = ""
            updates["focusedBrowserFindNeedle"] = ""
        }

        updates["terminalFindPanelId"] = terminalFind?.panelId.uuidString ?? ""
        updates["terminalFindNeedle"] = terminalFind?.needle ?? ""
        updates["terminalFindVisible"] = terminalFind == nil ? "false" : "true"

        updates["browserFindPanelId"] = browserFind?.panelId.uuidString ?? ""
        updates["browserFindNeedle"] = browserFind?.needle ?? ""
        updates["browserFindSelected"] = browserFind?.selected.map {
            String($0 + 1)
        } ?? ""
        updates["browserFindTotal"] = browserFind?.total.map(String.init) ?? ""
        updates["browserFindVisible"] = browserFind == nil ? "false" : "true"

        updates["firstResponderTerminalPanelId"] =
            firstResponderTerminalPanelId?.uuidString ?? ""

        return updates
    }
}
#endif
