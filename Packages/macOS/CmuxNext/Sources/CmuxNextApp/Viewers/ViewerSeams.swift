import AppKit
import CmuxNextActions
import CmuxNextDaemon

/// Opens a diff tab for a folder: the seam to the diff host (diff-host.md
/// S4), which `DiffPageService` fills (`DiffPageService+Viewers.swift`).
@MainActor
protocol DiffViewerOpening: AnyObject {
    /// Throws when nothing opens (no repository there, no diff host).
    /// `created` gets the new tab's surface when it is a store tab (one the
    /// daemon holds, so it can move between panes).
    func openDiff(directory: String, in pane: PaneController, focus: Bool,
                  created: (@MainActor (SurfaceID) -> Void)?) async throws
}

/// Opens a chosen file: the seam to the file pages (diff-host S6, S7),
/// ``FilePageOpener``. Returns why it did not open, nil when it did.
@MainActor
protocol FileOpening: AnyObject {
    func open(_ file: URL, in pane: PaneController?) -> String?
}
