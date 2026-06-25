// ProjectPanel, ProjectPanelTab, and ProjectPanelLoadState moved to the
// CmuxPanes package (Packages/macOS/CmuxPanes/Sources/CmuxPanes/Panel/ProjectPanel.swift).
//
// The project panel's runtime model has no app-target Workspace coupling and
// depends only on CMUXProjectModel plus the CmuxPanes Panel seam, so it lives
// in the panes domain package. The app-target ProjectPanel views
// (ProjectPanelView and the per-tab views) consume the moved model via
// `import CmuxPanes`.
//
// Slice seam (Panel-hierarchy wave): the WorkspacePanelHosting read seam now
// lives in CmuxPanes
// (Packages/macOS/CmuxPanes/Sources/CmuxPanes/Panel/WorkspacePanelHosting.swift),
// and the app target's `Workspace` conforms as the app-side witness
// (Sources/CmuxLifecycleEventPublishing.swift, the file that owns the
// `publishCmux*` hooks the seam forwards to). ProjectPanel takes only a project
// URL and reaches none of the workspace surface, so it does not hold a host;
// the seam exists for the panels whose `weak var workspace: Workspace`
// coupling it is designed to break (terminal/browser/agent-session, and
// FilePreview once its sibling cluster moves).
//
// FilePreviewPanel co-target — NOT moved, prereq recorded:
// FilePreviewPanel.swift's `FilePreviewPanel` class has NO `weak var workspace:
// Workspace` (post-ip4 it carries only a `workspaceId: UUID` value and the
// already-package CmuxPanes type WorkspaceAttentionFlashReason), so the
// WorkspacePanelHosting seam is not what blocks it. What blocks a faithful move
// is an app-target sibling-file cluster the class instantiates and references:
//   - FilePreviewFocusCoordinator (Sources/Panels/FilePreviewFocusCoordinator.swift,
//     uses Carbon.HIToolbox),
//   - FilePreviewNativeViewSessions (Sources/Panels/FilePreviewNativeViewSessions.swift)
//     -> FilePreviewPDFSession / FilePreviewImageSession / FilePreviewMediaSession
//        (Sources/Panels/FilePreviewMediaSession.swift) /
//        FilePreviewQuickLookSession (Sources/Panels/FilePreviewQuickLookSession.swift),
//     all built on PDFKit/AVKit/Quartz NSView hierarchies,
//   - FilePreviewTextEditingPanel + FilePreviewTextEditor
//     (Sources/Panels/FilePreviewTextEditor.swift),
//   - NotificationPaneFlashSettings (app-target settings type), and
//   - TerminalImageTransferPlanner (Sources/TerminalImageTransfer.swift), which
//     is terminal/Ghostty-neighborhood code the slice explicitly leaves in the
//     app target.
// Prereq before FilePreviewPanel can move: relocate that FilePreview* view/IO
// sibling cluster into CmuxPanes (CmuxPanes adds PDFKit/AVKit/Quartz imports as
// the spec allows), and either move TerminalImageTransferPlanner's text-insert
// helper into a shared package or pass the dropped-URL-insertion text in from
// the app target so the panel stops naming a terminal type. None of that is
// part of this slice; moving the class now without the cluster would leave a
// broken partial move, so it stays app-target until that prereq lands.
