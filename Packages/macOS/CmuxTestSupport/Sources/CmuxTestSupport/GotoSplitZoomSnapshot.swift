#if DEBUG
public import Foundation

/// A pure snapshot of the goto-split *split-zoom-toggle* capture fields for one
/// workspace, captured by the app-side `GotoSplitUITestRecorder` on the main
/// actor and formatted into the `*AfterToggle` `[String: String]` entries the
/// `CMUX_UI_TEST_GOTO_SPLIT_*` XCUITest zoom scenarios read back.
///
/// Only *reading* the live state is app-coupled: the split-zoom flags
/// (`bonsplitController.isSplitZoomed` / `zoomedPaneId`), the focused panel kind
/// (`focusedPanelId` + `terminalPanel(for:)`), and the browser / terminal
/// portal geometry are all read from `Workspace` / `Bonsplit` /
/// `BrowserWindowPortalRegistry` / AppKit, which a lower package cannot
/// reference. Turning those facts into the exact `*AfterToggle` capture-field
/// dictionary, and deciding whether the zoom has *settled*, is pure value
/// logic, so it moves here unchanged while the live reads stay behind
/// ``GotoSplitUITestRecorder`` app-side. ``captureFields`` and ``settled`` are
/// byte-identical to what the legacy nested `snapshot(for:)` produced.
///
/// Isolation: a `Sendable` value with no references; the recorder fills one in
/// per zoom-toggle capture turn and reads ``captureFields`` / ``settled``.
public struct GotoSplitZoomSnapshot: Sendable {
    /// The visibility / geometry of one portal-hosted surface (the browser
    /// container or the other terminal's hosted view) at capture time. Drives
    /// the `*HiddenAfterToggle` / `*VisibleFlagAfterToggle` / `*FrameAfterToggle`
    /// capture fields and the settle decision.
    public struct PortalGeometry: Sendable {
        /// Whether the host container is hidden (browser
        /// `containerHidden` / terminal `hostedView.isHidden`).
        public var isHidden: Bool
        /// Whether the surface reports itself visible in the UI (browser
        /// `visibleInUI` / terminal `debugPortalVisibleInUI`).
        public var isVisibleInUI: Bool
        /// The portal frame in window coordinates.
        public var frameInWindow: CGRect

        /// Creates a portal-geometry snapshot.
        public init(isHidden: Bool, isVisibleInUI: Bool, frameInWindow: CGRect) {
            self.isHidden = isHidden
            self.isVisibleInUI = isVisibleInUI
            self.frameInWindow = frameInWindow
        }

        /// The frame rendered as `"x,y wxh"` with one decimal place, matching the
        /// legacy `String(format: "%.1f,%.1f %.1fx%.1f", …)` formatting.
        public var frameDescription: String {
            String(
                format: "%.1f,%.1f %.1fx%.1f",
                frameInWindow.origin.x,
                frameInWindow.origin.y,
                frameInWindow.size.width,
                frameInWindow.size.height
            )
        }
    }

    /// Whether the workspace is split-zoomed (`bonsplitController.isSplitZoomed`).
    public var isSplitZoomed: Bool

    /// The zoomed pane id rendered with `description`, or `nil` when none.
    public var zoomedPaneId: String?

    /// Whether the focused panel resolves to a terminal panel. Mirrors the
    /// legacy `focusedPanelId` + `terminalPanel(for:)` branch in the settle
    /// decision.
    public var focusedPanelIsTerminal: Bool

    /// The first browser panel's id rendered with `uuidString`, or `nil`. Note
    /// this is independent of ``browserPortal``: the panel can exist while the
    /// portal snapshot is absent.
    public var browserPanelId: String?

    /// The first browser panel's portal geometry, if a portal snapshot exists.
    public var browserPortal: PortalGeometry?

    /// The first terminal panel's id rendered with `uuidString`, or `nil`.
    public var otherTerminalPanelId: String?

    /// The first terminal panel's hosted-view portal geometry, if that panel
    /// exists.
    public var otherTerminalPortal: PortalGeometry?

    /// Creates a zoom-toggle snapshot from the app-side reads.
    public init(
        isSplitZoomed: Bool,
        zoomedPaneId: String?,
        focusedPanelIsTerminal: Bool,
        browserPanelId: String?,
        browserPortal: PortalGeometry?,
        otherTerminalPanelId: String?,
        otherTerminalPortal: PortalGeometry?
    ) {
        self.isSplitZoomed = isSplitZoomed
        self.zoomedPaneId = zoomedPaneId
        self.focusedPanelIsTerminal = focusedPanelIsTerminal
        self.browserPanelId = browserPanelId
        self.browserPortal = browserPortal
        self.otherTerminalPanelId = otherTerminalPanelId
        self.otherTerminalPortal = otherTerminalPortal
    }

    /// The `*AfterToggle` capture-field object, byte-identical to the entries the
    /// legacy nested `snapshot(for:)` set on top of the find-state snapshot.
    public var captureFields: [String: String] {
        var updates: [String: String] = [:]
        updates["splitZoomedAfterToggle"] = isSplitZoomed ? "true" : "false"
        updates["zoomedPaneIdAfterToggle"] = zoomedPaneId ?? ""
        updates["browserPanelIdAfterToggle"] = browserPanelId ?? ""
        updates["browserContainerHiddenAfterToggle"] = browserPortal.map { $0.isHidden ? "true" : "false" } ?? ""
        updates["browserVisibleFlagAfterToggle"] = browserPortal.map { $0.isVisibleInUI ? "true" : "false" } ?? ""
        updates["browserFrameAfterToggle"] = browserPortal.map { $0.frameDescription } ?? ""
        updates["otherTerminalPanelIdAfterToggle"] = otherTerminalPanelId ?? ""
        updates["otherTerminalHostHiddenAfterToggle"] = otherTerminalPortal.map { $0.isHidden ? "true" : "false" } ?? ""
        updates["otherTerminalVisibleFlagAfterToggle"] = otherTerminalPortal.map { $0.isVisibleInUI ? "true" : "false" } ?? ""
        updates["otherTerminalFrameAfterToggle"] = otherTerminalPortal.map { $0.frameDescription } ?? ""
        return updates
    }

    /// Whether the zoom toggle has settled into its expected geometry, matching
    /// the legacy nested `settled` computation exactly.
    public var settled: Bool {
        if isSplitZoomed {
            if focusedPanelIsTerminal {
                guard let browserPortal else { return false }
                return browserPortal.isHidden && !browserPortal.isVisibleInUI
            }
            guard let otherTerminalPortal else { return true }
            return otherTerminalPortal.isHidden && !otherTerminalPortal.isVisibleInUI
        }
        let browserRestored = browserPortal.map { !$0.isHidden && $0.isVisibleInUI } ?? true
        let terminalRestored = otherTerminalPortal.map { !$0.isHidden && $0.isVisibleInUI } ?? true
        return browserRestored && terminalRestored
    }
}
#endif
