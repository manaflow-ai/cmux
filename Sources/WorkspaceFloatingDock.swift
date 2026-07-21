import CoreGraphics
import Foundation
import Observation

final class WorkspaceFloatingDockNoteWriter: @unchecked Sendable {
    private let sequenceLock = NSLock()
    private let writeLock = NSLock()
    private var nextSequence: UInt64 = 0
    private var latestCommittedSequence: UInt64 = 0
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func reserveSequence() -> UInt64 {
        sequenceLock.withLock {
            nextSequence &+= 1
            return nextSequence
        }
    }

    func saveSynchronously(
        content: String,
        encoding: String.Encoding = .utf8,
        sequence requestedSequence: UInt64? = nil
    ) -> FilePreviewTextSaver.Result {
        let sequence = sequenceLock.withLock {
            if let requestedSequence {
                return requestedSequence
            } else {
                nextSequence &+= 1
                return nextSequence
            }
        }
        return writeLock.withLock {
            let isCurrent = sequenceLock.withLock { sequence >= latestCommittedSequence }
            guard isCurrent else { return .saved }
            let result = FilePreviewTextSaver.saveSynchronously(
                content: content,
                to: fileURL,
                encoding: encoding,
                options: .atomic
            )
            if case .saved = result {
                sequenceLock.withLock {
                    latestCommittedSequence = max(latestCommittedSequence, sequence)
                }
            }
            return result
        }
    }

    func save(
        content: String,
        encoding: String.Encoding,
        sequence: UInt64
    ) async -> FilePreviewTextSaver.Result {
        await Task.detached(priority: .userInitiated) { [self] in
            saveSynchronously(content: content, encoding: encoding, sequence: sequence)
        }.value
    }
}

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
    @ObservationIgnored let noteWriter: WorkspaceFloatingDockNoteWriter
    @ObservationIgnored private(set) var initialContentWasCreated = true

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
        let noteWriter = WorkspaceFloatingDockNoteWriter(
            fileURL: URL(fileURLWithPath: noteFilePath)
        )
        self.noteWriter = noteWriter
        self.store = DockSplitStore(
            workspaceId: workspaceId,
            scope: .workspace,
            loadsConfiguration: false,
            baseDirectoryProvider: baseDirectoryProvider,
            remoteBrowserSettingsProvider: remoteBrowserSettingsProvider,
            terminalTransferProvider: terminalTransferProvider,
            noteTextSaver: { content, _, encoding, sequence in
                let sequence = sequence ?? noteWriter.reserveSequence()
                return await noteWriter.save(
                    content: content,
                    encoding: encoding,
                    sequence: sequence
                )
            },
            noteTextSaveSequenceProvider: { noteWriter.reserveSequence() }
        )
        loadPersistedNoteSnapshot()

        if let initialContent {
            initialContentWasCreated = seedInitialContentIfNeeded(initialContent, url: initialURL)
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
        _ = seedInitialContentIfNeeded(.terminal)
    }

    @discardableResult
    private func seedInitialContentIfNeeded(_ kind: DockSurfaceKind, url: URL? = nil) -> Bool {
        guard store.panels.isEmpty else { return true }
        guard let rootPane = store.bonsplitController.allPaneIds.first else { return false }
        guard let panelId = store.newSurface(
            kind: kind,
            inPane: rootPane,
            url: url,
            noteFilePath: kind == .note ? noteFilePath : nil,
            noteTitle: kind == .note
                ? String(localized: "floatingDock.note.title", defaultValue: "Notes")
                : nil,
            focus: false
        ) else { return false }
        if kind == .note {
            notePanelId = panelId
            bindNotePanel()
        }
        return true
    }

    func setNoteTextSnapshot(_ text: String) {
        noteTextGeneration += 1
        noteTextSnapshot = text
    }

    var noteSnapshotGeneration: Int { noteTextGeneration }

    func applyPersistedNoteText(_ text: String, to panel: FilePreviewPanel?) -> Bool {
        do {
            try panel?.applyPersistedAutosavedTextContent(text)
            setNoteTextSnapshot(text)
            return true
        } catch {
            return false
        }
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
