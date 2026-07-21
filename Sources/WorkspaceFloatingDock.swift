import CoreGraphics
import Foundation
import Observation

final class WorkspaceFloatingDockNoteWriter: @unchecked Sendable {
    struct Persistence: Sendable {
        let save: @Sendable (
            String,
            URL,
            String.Encoding,
            UInt64?
        ) async -> FilePreviewTextSaver.Result
        let saveSynchronously: @Sendable (
            String,
            URL,
            String.Encoding,
            UInt64?
        ) -> FilePreviewTextSaver.Result
        let reserveSequence: @Sendable () -> UInt64
    }

    private let sequenceLock = NSLock()
    private let writeLock = NSLock()
    private let controlWriteCondition = NSCondition()
    private var nextSequence: UInt64 = 0
    private var latestCommittedSequence: UInt64 = 0
    private var inFlightControlWriteSequences: Set<UInt64> = []
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var persistence: Persistence {
        Persistence(
            save: { [self] content, _, encoding, sequence in
                await self.save(
                    content: content,
                    encoding: encoding,
                    sequence: sequence ?? self.reserveSequence()
                )
            },
            saveSynchronously: { [self] content, _, encoding, sequence in
                self.saveSynchronously(
                    content: content,
                    encoding: encoding,
                    sequence: sequence
                )
            },
            reserveSequence: { [self] in self.reserveSequence() }
        )
    }

    func reserveSequence() -> UInt64 {
        sequenceLock.withLock {
            nextSequence &+= 1
            return nextSequence
        }
    }

    /// Reserves a socket mutation before its worker leaves the main actor.
    /// Reads that were prepared later wait for this mutation, preserving the
    /// request order even when separate socket workers reach disk out of order.
    func reserveControlWriteSequence() -> UInt64 {
        controlWriteCondition.lock()
        defer { controlWriteCondition.unlock() }
        let sequence = reserveSequence()
        inFlightControlWriteSequences.insert(sequence)
        return sequence
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
        defer { finishControlWrite(sequence: sequence) }
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

    /// Loads behind every socket write that had already been reserved. Holding
    /// the condition until the read owns `writeLock` also gives later writes a
    /// well-defined order after this read.
    func loadSynchronously(
        using loader: WorkspaceFloatingDockNoteLoader
    ) -> FilePreviewTextLoader.Result {
        controlWriteCondition.lock()
        while !inFlightControlWriteSequences.isEmpty {
            controlWriteCondition.wait()
        }
        writeLock.lock()
        controlWriteCondition.unlock()
        defer { writeLock.unlock() }
        return loader.loadSynchronously()
    }

    private func finishControlWrite(sequence: UInt64) {
        controlWriteCondition.lock()
        defer { controlWriteCondition.unlock() }
        guard inFlightControlWriteSequences.remove(sequence) != nil else { return }
        controlWriteCondition.broadcast()
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
        let persistence = writer.persistence
        return FilePreviewPanel(
            workspaceId: workspaceId,
            filePath: filePath,
            presentation: presentation,
            textSaver: persistence.save,
            textSaveSequenceProvider: persistence.reserveSequence
        )
    }
}

@MainActor
enum WorkspaceFloatingDockNoteOwnerRegistry {
    private final class WeakDock {
        weak var value: WorkspaceFloatingDock?

        init(_ value: WorkspaceFloatingDock) {
            self.value = value
        }
    }

    private final class WeakPanel {
        weak var value: FilePreviewPanel?

        init(_ value: FilePreviewPanel) {
            self.value = value
        }
    }

    private static var owners: [String: WeakDock] = [:]
    private static var panels: [String: [WeakPanel]] = [:]

    static func register(_ dock: WorkspaceFloatingDock) {
        let key = canonicalPath(dock.noteFilePath)
        owners[key] = WeakDock(dock)
        livePanels(forKey: key).forEach { dock.bindManagedNotePanel($0) }
    }

    static func unregister(_ dock: WorkspaceFloatingDock) {
        let key = canonicalPath(dock.noteFilePath)
        if owners[key]?.value === dock {
            owners.removeValue(forKey: key)
        }
        _ = livePanels(forKey: key)
    }

    static func register(_ panel: FilePreviewPanel) {
        guard panel.presentation.autosavesTextChanges else { return }
        let key = canonicalPath(panel.filePath)
        var live = livePanels(forKey: key)
        if !live.contains(where: { $0 === panel }) {
            live.append(panel)
            panels[key] = live.map(WeakPanel.init)
        }
        owner(forKey: key)?.bindManagedNotePanel(panel)
    }

    static func unregister(_ panel: FilePreviewPanel) {
        let key = canonicalPath(panel.filePath)
        let live = livePanels(forKey: key).filter { $0 !== panel }
        if live.isEmpty {
            panels.removeValue(forKey: key)
        } else {
            panels[key] = live.map(WeakPanel.init)
        }
    }

    static func panels(for dock: WorkspaceFloatingDock) -> [FilePreviewPanel] {
        livePanels(forKey: canonicalPath(dock.noteFilePath))
    }

    private static func owner(forKey key: String) -> WorkspaceFloatingDock? {
        guard let owner = owners[key]?.value else {
            owners.removeValue(forKey: key)
            return nil
        }
        return owner
    }

    private static func livePanels(forKey key: String) -> [FilePreviewPanel] {
        let live = panels[key, default: []].compactMap(\.value)
        if live.isEmpty {
            panels.removeValue(forKey: key)
        } else {
            panels[key] = live.map(WeakPanel.init)
        }
        return live
    }

    private static func canonicalPath(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }
}

/// Performs bounded, on-demand persisted-note reads without retaining their
/// contents. The live editor or mutation snapshot owns text once it is needed.
final class WorkspaceFloatingDockNoteLoader: @unchecked Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func loadSynchronously() -> FilePreviewTextLoader.Result {
        FilePreviewTextLoader.loadSynchronously(url: fileURL)
    }

    func load() async -> FilePreviewTextLoader.Result {
        await FilePreviewTextLoader.load(url: fileURL)
    }
}

/// One window-like Bonsplit container owned by a workspace.
@MainActor
@Observable
final class WorkspaceFloatingDock: Identifiable {
    let id: UUID
    let workspaceId: UUID
    var title: String {
        didSet { if title != oldValue { sessionMetadataRevision &+= 1 } }
    }
    var frame: CGRect {
        didSet { if frame != oldValue { sessionMetadataRevision &+= 1 } }
    }
    var isPresented: Bool {
        didSet { if isPresented != oldValue { sessionMetadataRevision &+= 1 } }
    }
    var backgroundTintHex: String? {
        didSet { if backgroundTintHex != oldValue { sessionMetadataRevision &+= 1 } }
    }
    var ownsInputFocus = false

    @ObservationIgnored var screenFrame: CGRect? {
        didSet { if screenFrame != oldValue { sessionMetadataRevision &+= 1 } }
    }
    @ObservationIgnored var displaySnapshot: SessionDisplaySnapshot? {
        didSet { if displaySnapshot != oldValue { sessionMetadataRevision &+= 1 } }
    }
    @ObservationIgnored var configFrames: SessionConfigFrameRing {
        didSet { if configFrames != oldValue { sessionMetadataRevision &+= 1 } }
    }
    @ObservationIgnored private(set) var sessionMetadataRevision: UInt64 = 0
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
        let notePersistence = noteWriter.persistence
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
            noteTextSaver: notePersistence.save,
            noteTextSaveSequenceProvider: notePersistence.reserveSequence
        )

        WorkspaceFloatingDockNoteOwnerRegistry.register(self)
        if let initialContent {
            initialContentWasCreated = seedInitialContentIfNeeded(initialContent, url: initialURL)
        }
    }

    var notePanel: FilePreviewPanel? {
        if let notePanelId,
           let panel = store.panels[notePanelId] as? FilePreviewPanel,
           isManagedNotePanel(panel) {
            return panel
        }
        return store.panels.values.compactMap { $0 as? FilePreviewPanel }.first {
            isManagedNotePanel($0)
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
        return (noteTextGeneration, noteWriter.reserveControlWriteSequence())
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
        return noteTextSnapshot
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
        WorkspaceFloatingDockNoteOwnerRegistry.register(panel)
    }

    func bindManagedNotePanel(_ panel: FilePreviewPanel) {
        guard isManagedNotePanel(panel) else { return }
        guard panel.rebindAutosavingTextPersistence(noteWriter.persistence) else {
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel,
                      await panel.flushPendingAutosave() else { return }
                self.bindManagedNotePanel(panel)
            }
            return
        }
        panel.autosavedTextDidChange = { [weak self] text in
            self?.setNoteTextSnapshot(text)
        }
    }

    private func isManagedNotePanel(_ panel: FilePreviewPanel) -> Bool {
        panel.presentation.autosavesTextChanges
            && (panel.filePath as NSString).resolvingSymlinksInPath
                == (noteFilePath as NSString).resolvingSymlinksInPath
    }

    func close() {
        ownsInputFocus = false
        WorkspaceFloatingDockNoteOwnerRegistry.panels(for: self).forEach {
            $0.autosavedTextDidChange = nil
        }
        WorkspaceFloatingDockNoteOwnerRegistry.unregister(self)
        store.closeAllPanels()
    }
}
