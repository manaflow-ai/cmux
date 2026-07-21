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
                maximumBytes: FilePreviewTextLoader.maximumLoadedTextBytes,
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

    @MainActor
    static func makeFilePreviewPanel(
        workspaceId: UUID,
        filePath: String,
        presentation: FilePreviewPresentation
    ) -> FilePreviewPanel {
        guard presentation.autosavesTextChanges else {
            return FilePreviewPanel(
                workspaceId: workspaceId,
                filePath: filePath,
                presentation: presentation
            )
        }
        let writer = WorkspaceFloatingDockNoteWriter(
            fileURL: URL(fileURLWithPath: filePath)
        )
        return FilePreviewPanel(
            workspaceId: workspaceId,
            filePath: filePath,
            presentation: presentation,
            textSaver: { content, _, encoding, sequence in
                await writer.save(
                    content: content,
                    encoding: encoding,
                    sequence: sequence ?? writer.reserveSequence()
                )
            },
            textSaverSynchronously: { content, _, encoding, sequence in
                writer.saveSynchronously(
                    content: content,
                    encoding: encoding,
                    sequence: sequence
                )
            },
            textSaveSequenceProvider: { writer.reserveSequence() }
        )
    }
}

/// Coalesces the initial persisted-note read across the background preload and
/// concurrent socket callers. Disk I/O stays off the main actor, while every
/// waiter observes the same completed result.
final class WorkspaceFloatingDockNoteLoader: @unchecked Sendable {
    private enum State {
        case unloaded
        case loading
        case loaded(FilePreviewTextLoader.Result)
    }

    private let condition = NSCondition()
    private var state: State = .unloaded
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func loadSynchronously() -> FilePreviewTextLoader.Result {
        condition.lock()
        while true {
            switch state {
            case .loaded(let result):
                condition.unlock()
                return result
            case .loading:
                condition.wait()
            case .unloaded:
                state = .loading
                condition.unlock()
                let result = FilePreviewTextLoader.loadSynchronously(url: fileURL)
                condition.lock()
                state = .loaded(result)
                condition.broadcast()
                condition.unlock()
                return result
            }
        }
    }

    func load() async -> FilePreviewTextLoader.Result {
        await Task.detached(priority: .userInitiated) { [self] in
            loadSynchronously()
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
    @ObservationIgnored private var noteSnapshotIsLoaded = false
    @ObservationIgnored let noteWriter: WorkspaceFloatingDockNoteWriter
    @ObservationIgnored let noteLoader: WorkspaceFloatingDockNoteLoader
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
        surfaceCreationAllowedProvider: @escaping () -> Bool = { true },
        terminalTransferProvider: DockSplitStore.TerminalTransferProvider? = nil,
        terminalRestoreTransferProvider: DockSplitStore.TerminalRestoreTransferProvider? = nil
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
        let noteFileURL = URL(fileURLWithPath: noteFilePath)
        let noteWriter = WorkspaceFloatingDockNoteWriter(fileURL: noteFileURL)
        self.noteWriter = noteWriter
        self.noteLoader = WorkspaceFloatingDockNoteLoader(fileURL: noteFileURL)
        self.store = DockSplitStore(
            workspaceId: workspaceId,
            scope: .workspace,
            loadsConfiguration: false,
            baseDirectoryProvider: baseDirectoryProvider,
            remoteBrowserSettingsProvider: remoteBrowserSettingsProvider,
            surfaceCreationAllowedProvider: surfaceCreationAllowedProvider,
            terminalTransferProvider: terminalTransferProvider,
            terminalRestoreTransferProvider: terminalRestoreTransferProvider,
            noteTextSaver: { content, _, encoding, sequence in
                let sequence = sequence ?? noteWriter.reserveSequence()
                return await noteWriter.save(
                    content: content,
                    encoding: encoding,
                    sequence: sequence
                )
            },
            noteTextSaverSynchronously: { content, _, encoding, sequence in
                noteWriter.saveSynchronously(
                    content: content,
                    encoding: encoding,
                    sequence: sequence
                )
            },
            noteTextSaveSequenceProvider: { noteWriter.reserveSequence() }
        )

        if let initialContent {
            initialContentWasCreated = seedInitialContentIfNeeded(initialContent, url: initialURL)
        }
        loadPersistedNoteSnapshot()
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
        noteSnapshotIsLoaded = true
        noteTextSnapshot = text
    }

    var noteSnapshotGeneration: Int { noteTextGeneration }

    func reserveNoteMutation() -> (snapshotGeneration: Int, writeSequence: UInt64) {
        noteTextGeneration += 1
        noteSnapshotIsLoaded = true
        return (noteTextGeneration, noteWriter.reserveSequence())
    }

    var loadedNoteTextSnapshot: String? {
        noteSnapshotIsLoaded ? noteTextSnapshot : nil
    }

    func reserveNoteSnapshotRead() -> Int {
        noteTextGeneration
    }

    func applyLoadedNoteTextSnapshot(_ text: String, generation: Int) -> String {
        guard noteTextGeneration == generation else { return noteTextSnapshot }
        setNoteTextSnapshot(text)
        return text
    }

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
        panel.autosavedTextDidChange = { [weak self] text in
            self?.setNoteTextSnapshot(text)
        }
    }

    private func loadPersistedNoteSnapshot() {
        let generation = noteTextGeneration
        let loader = noteLoader
        Task { [weak self, loader, generation] in
            let result = await loader.load()
            guard let self else { return }
            switch result {
            case .loaded(let text, _):
                _ = self.applyLoadedNoteTextSnapshot(text, generation: generation)
            case .unavailable:
                _ = self.applyLoadedNoteTextSnapshot("", generation: generation)
            }
        }
    }

    func close() {
        ownsInputFocus = false
        notePanel?.autosavedTextDidChange = nil
        store.closeAllPanels()
    }
}
