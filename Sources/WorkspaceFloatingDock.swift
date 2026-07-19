import CoreGraphics
import Foundation
import Observation

/// One window-like Bonsplit container owned by a workspace.
@MainActor
@Observable
final class WorkspaceFloatingDock: Identifiable {
    let id: UUID
    let workspaceId: UUID
    var title: String
    var frame: CGRect
    var isPresented: Bool
    var backgroundTintHex: String?
    var ownsInputFocus = false

    @ObservationIgnored var screenFrame: CGRect?
    @ObservationIgnored var displaySnapshot: SessionDisplaySnapshot?
    @ObservationIgnored var configFrames: SessionConfigFrameRing
    @ObservationIgnored let store: DockSplitStore
    @ObservationIgnored let noteFilePath: String
    @ObservationIgnored private(set) var notePanelId: UUID?

    init(
        id: UUID,
        workspaceId: UUID,
        title: String,
        frame: CGRect,
        isPresented: Bool,
        noteFilePath: String,
        backgroundTintHex: String? = nil,
        initialContent: DockSurfaceKind? = .note,
        initialURL: URL? = nil,
        screenFrame: CGRect? = nil,
        displaySnapshot: SessionDisplaySnapshot? = nil,
        configFrames: SessionConfigFrameRing = SessionConfigFrameRing(),
        baseDirectoryProvider: @escaping () -> String?,
        remoteBrowserSettingsProvider: @escaping () -> DockRemoteBrowserSettings
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.title = title
        self.frame = frame
        self.isPresented = isPresented
        self.backgroundTintHex = backgroundTintHex
        self.screenFrame = screenFrame
        self.displaySnapshot = displaySnapshot
        self.configFrames = configFrames
        self.noteFilePath = noteFilePath
        self.store = DockSplitStore(
            workspaceId: workspaceId,
            scope: .workspace,
            loadsConfiguration: false,
            baseDirectoryProvider: baseDirectoryProvider,
            remoteBrowserSettingsProvider: remoteBrowserSettingsProvider
        )

        if let initialContent {
            seedInitialContentIfNeeded(initialContent, url: initialURL)
        }
    }

    var notePanel: FilePreviewPanel? {
        if let notePanelId, let panel = store.panels[notePanelId] as? FilePreviewPanel {
            return panel
        }
        return store.panels.values.first(where: { $0 is FilePreviewPanel }) as? FilePreviewPanel
    }

    func sessionContentSnapshot() -> SessionFloatingDockContentSnapshot? {
        store.floatingDockSessionSnapshot(notePanelId: notePanel?.id)
    }

    func restoreSessionContent(_ snapshot: SessionFloatingDockContentSnapshot) {
        notePanelId = store.restoreFloatingDockSessionSnapshot(
            snapshot,
            noteFilePath: noteFilePath,
            noteTitle: String(localized: "floatingDock.note.title", defaultValue: "Notes")
        )
        seedInitialContentIfNeeded(.terminal)
    }

    private func seedInitialContentIfNeeded(_ kind: DockSurfaceKind, url: URL? = nil) {
        guard store.panels.isEmpty,
              let rootPane = store.bonsplitController.allPaneIds.first else { return }
        let panelId = store.newSurface(
            kind: kind,
            inPane: rootPane,
            url: url,
            noteFilePath: kind == .note ? noteFilePath : nil,
            noteTitle: kind == .note
                ? String(localized: "floatingDock.note.title", defaultValue: "Notes")
                : nil,
            focus: false
        )
        if kind == .note {
            notePanelId = panelId
        }
    }

    func close() {
        ownsInputFocus = false
        store.closeAllPanels()
    }
}
