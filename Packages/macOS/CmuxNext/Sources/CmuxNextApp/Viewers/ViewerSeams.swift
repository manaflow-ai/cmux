import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDiff

/// Opens a diff tab for a folder: the seam to the diff host (diff-host.md
/// S4), which `DiffPageService` fills (`DiffPageService+Viewers.swift`).
@MainActor
protocol DiffViewerOpening: AnyObject {
    /// Throws when nothing opens (no repository there, no diff host).
    /// `created` gets the new tab's surface when it is a store tab (one the
    /// daemon holds, so it can move between panes). `turn`: the chat turn the tab offers as Last
    /// turn; `showTurn` opens the tab on it (an edited-files card). `onPaneMachine`: `directory` is
    /// a folder of `pane`'s machine (its terminal's, or one the CLI or a chat named there; #25581,
    /// a Cloud workspace's), not one this Mac's picker chose.
    func openDiff(directory: String, turn: DiffTurn?, showTurn: Bool, in pane: PaneController, focus: Bool,
                  onPaneMachine: Bool, created: (@MainActor (SurfaceID) -> Void)?) async throws
}

/// Opens a chosen file: the seam to the file pages (diff-host S6, S7),
/// ``FilePageOpener``. Returns why it did not open, nil when it did.
@MainActor
protocol FileOpening: AnyObject {
    func open(_ file: URL, in pane: PaneController?) -> String?
}
