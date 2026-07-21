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
    @ObservationIgnored private(set) var noteTextSnapshot = ""
    @ObservationIgnored private var noteTextGeneration = 0
    @ObservationIgnored private let notePersistenceQueue: DispatchQueue

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
        remoteBrowserSettingsProvider: @escaping () -> DockRemoteBrowserSettings,
        terminalTransferProvider: DockSplitStore.TerminalTransferProvider? = nil
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
        self.notePersistenceQueue = DispatchQueue(
            label: "com.cmuxterm.floating-dock-note.\(id.uuidString.lowercased())"
        )
        self.store = DockSplitStore(
            workspaceId: workspaceId,
            scope: .workspace,
            loadsConfiguration: false,
            baseDirectoryProvider: baseDirectoryProvider,
            remoteBrowserSettingsProvider: remoteBrowserSettingsProvider,
            terminalTransferProvider: terminalTransferProvider
        )
        loadPersistedNoteSnapshot()

        if let initialContent {
            seedInitialContentIfNeeded(initialContent, url: initialURL)
        }
    }

    var notePanel: FilePreviewPanel? {
        if let notePanelId, let panel = store.panels[notePanelId] as? FilePreviewPanel {
            return panel
        }
        return store.panels.values.compactMap { $0 as? FilePreviewPanel }.first {
            $0.filePath == noteFilePath && $0.presentation.autosavesTextChanges
        }
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
        bindNotePanel()
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
            bindNotePanel()
        }
    }

    func setNoteTextSnapshot(_ text: String) {
        noteTextGeneration += 1
        noteTextSnapshot = text
    }

    func persistNoteTextSnapshot(_ text: String) -> Bool {
        let url = URL(fileURLWithPath: noteFilePath)
        let result = notePersistenceQueue.sync {
            FilePreviewTextSaver.saveSynchronously(content: text, to: url, encoding: .utf8)
        }
        guard case .saved = result else { return false }
        setNoteTextSnapshot(text)
        return true
    }

    private func bindNotePanel() {
        guard let panel = notePanel else { return }
        setNoteTextSnapshot(panel.textContent)
        panel.autosavedTextDidChange = { [weak self] text in
            self?.setNoteTextSnapshot(text)
        }
    }

    private func loadPersistedNoteSnapshot() {
        let path = noteFilePath
        let generation = noteTextGeneration
        Task { [weak self, path, generation] in
            guard case .loaded(let text, _) = await FilePreviewTextLoader.load(
                url: URL(fileURLWithPath: path)
            ), let self, self.noteTextGeneration == generation else { return }
            self.noteTextSnapshot = text
        }
    }

    func close() {
        ownsInputFocus = false
        notePanel?.autosavedTextDidChange = nil
        store.closeAllPanels()
    }
}
