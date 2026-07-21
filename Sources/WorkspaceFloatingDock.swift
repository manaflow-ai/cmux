import CoreGraphics
import Foundation
import Observation

/// One window-like Bonsplit container owned by a workspace.
@MainActor
@Observable
final class WorkspaceFloatingDock: Identifiable {
    enum Persistence: Equatable, Sendable {
        case session
        case transient
    }

    enum CloseBehavior: Equatable, Sendable {
        case remove
        case hide
    }

    let id: UUID
    let workspaceId: UUID
    let persistence: Persistence
    let closeBehavior: CloseBehavior
    var title: String
    var frame: CGRect
    var isPresented: Bool
    var ownsInputFocus = false

    @ObservationIgnored let store: DockSplitStore
    @ObservationIgnored let noteFilePath: String?
    @ObservationIgnored private let seedsDefaultNote: Bool
    @ObservationIgnored private(set) var notePanelId: UUID?

    init(
        id: UUID,
        workspaceId: UUID,
        title: String,
        frame: CGRect,
        isPresented: Bool,
        persistence: Persistence = .session,
        closeBehavior: CloseBehavior = .remove,
        contentPolicy: DockSplitStore.ContentPolicy = .flexible,
        noteFilePath: String?,
        seedsDefaultNote: Bool = true,
        baseDirectoryProvider: @escaping () -> String?,
        remoteBrowserSettingsProvider: @escaping () -> DockRemoteBrowserSettings
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.title = title
        self.frame = frame
        self.isPresented = isPresented
        self.persistence = persistence
        self.closeBehavior = closeBehavior
        self.noteFilePath = noteFilePath
        self.seedsDefaultNote = seedsDefaultNote
        self.store = DockSplitStore(
            workspaceId: workspaceId,
            scope: .workspace,
            loadsConfiguration: false,
            contentPolicy: contentPolicy,
            baseDirectoryProvider: baseDirectoryProvider,
            remoteBrowserSettingsProvider: remoteBrowserSettingsProvider
        )

        if seedsDefaultNote {
            seedDefaultNoteIfNeeded()
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
        guard let noteFilePath else { return }
        notePanelId = store.restoreFloatingDockSessionSnapshot(
            snapshot,
            noteFilePath: noteFilePath,
            noteTitle: String(localized: "floatingDock.note.title", defaultValue: "Notes")
        )
        seedDefaultNoteIfNeeded()
    }

    private func seedDefaultNoteIfNeeded() {
        guard seedsDefaultNote,
              let noteFilePath,
              notePanel == nil,
              let rootPane = store.bonsplitController.allPaneIds.first else { return }
        notePanelId = store.newSurface(
            kind: .note,
            inPane: rootPane,
            noteFilePath: noteFilePath,
            noteTitle: String(localized: "floatingDock.note.title", defaultValue: "Notes"),
            focus: false
        )
    }

    func close() {
        ownsInputFocus = false
        store.closeAllPanels()
    }
}
