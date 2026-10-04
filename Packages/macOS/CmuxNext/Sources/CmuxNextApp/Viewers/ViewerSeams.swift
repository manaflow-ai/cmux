import AppKit
import CmuxNextActions

/// Opens a diff tab for a folder: the seam to the diff host (diff-host.md
/// S4), which `DiffPageService` fills (`DiffPageService+Viewers.swift`).
@MainActor
protocol DiffViewerOpening: AnyObject {
    /// Throws when nothing opens (no repository there, no diff host).
    func openDiff(directory: String, in pane: PaneController, focus: Bool) async throws
}

/// Opens a chosen file: the seam to the code editor page (cmux.editor,
/// Monaco), which a separate lane is building. cmux-next has no file
/// viewer surface, so until that page lands ``BrowserTabFileOpener`` opens
/// the file the way `file.open` does today: a browser tab on its file URL.
/// Returns why it did not open, nil when it did.
@MainActor
protocol FileOpening: AnyObject {
    func open(_ file: URL, in pane: PaneController?) -> String?
}
