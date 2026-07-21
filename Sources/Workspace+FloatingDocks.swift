import AppKit
import Bonsplit
import CmuxControlSocket
import CmuxWorkspaces
import CoreGraphics
import Foundation

extension Workspace {
    var controlReportingSurfaceIds: Set<UUID> {
        var result = Set(panels.keys)
        if let dock = _dockSplit {
            result.formUnion(dock.panels.keys)
        }
        for floatingDock in floatingDocks {
            result.formUnion(floatingDock.store.panels.keys)
        }
        return result
    }

    var controlReportingFocusedSurfaceId: UUID? {
        if let floatingPanelId = floatingDocks
            .first(where: \.ownsInputFocus)?
            .store.focusedPanelId {
            return floatingPanelId
        }
        if let focusedPanelId, panels[focusedPanelId] != nil {
            return focusedPanelId
        }
        if let dock = _dockSplit, dock.isVisibleInUI, let dockPanelId = dock.focusedPanelId {
            return dockPanelId
        }
        return nil
    }

    func controlOwnedPanel(for panelId: UUID) -> (any Panel)? {
        if let panel = panels[panelId] { return panel }
        if let panel = _dockSplit?.panels[panelId] { return panel }
        return floatingDocks.lazy.compactMap { $0.store.panels[panelId] }.first
    }

    func controlOwningDockStore(for panelId: UUID) -> DockSplitStore? {
        if let dock = _dockSplit, dock.containsPanel(panelId) { return dock }
        return floatingDocks.lazy.map(\.store).first { $0.containsPanel(panelId) }
    }

    func updateDockTransferReportedState(
        panelId: UUID,
        directory: String? = nil,
        directoryDisplayLabel: String? = nil,
        ttyName: String? = nil,
        shellActivityState: PanelShellActivityState? = nil
    ) {
        guard let dock = controlOwningDockStore(for: panelId),
              let transfer = dock.detachedSurfaceTransfersByPanelId[panelId] else { return }
        dock.detachedSurfaceTransfersByPanelId[panelId] = transfer.withReportedState(
            directory: directory,
            directoryDisplayLabel: directoryDisplayLabel,
            ttyName: ttyName,
            shellActivityState: shellActivityState
        )
    }

    func isDockTransferredRemoteTerminal(_ panelId: UUID) -> Bool {
        controlOwningDockStore(for: panelId)?
            .detachedSurfaceTransfersByPanelId[panelId]?
            .isRemoteTerminal == true
    }

    func recordReportedSurfaceTTY(_ ttyName: String, panelId: UUID) {
        surfaceTTYNames[panelId] = ttyName
        updateDockTransferReportedState(panelId: panelId, ttyName: ttyName)
    }

    func discardDockSurfaceReportingState(panelId: UUID) {
        PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
        pruneSurfaceMetadata(validSurfaceIds: controlReportingSurfaceIds.subtracting([panelId]))
        recomputeListeningPorts()
        syncRemotePortScanTTYs()
    }

    /// Creates a workspace-scoped floating window with one native Bonsplit surface.
    @discardableResult
    func createFloatingDock(
        id: UUID = UUID(),
        title: String? = nil,
        frame: CGRect? = nil,
        isPresented: Bool = true,
        initialContent: DockSurfaceKind = .terminal,
        initialURL: URL? = nil,
        backgroundTintHex: String? = nil,
        sessionContent: SessionFloatingDockContentSnapshot? = nil,
        screenFrame: CGRect? = nil,
        displaySnapshot: SessionDisplaySnapshot? = nil,
        configFrames: [SessionConfigFrameEntry]? = nil,
        snapshotWorkspaceId: UUID? = nil,
        snapshotWorkspaceStableId: UUID? = nil,
        snapshotManagedNoteFilePath: String? = nil,
        resolvedManagedNoteFileURL: URL? = nil
    ) -> WorkspaceFloatingDock? {
        guard floatingDocks.count < SessionPersistencePolicy.maxFloatingDocksPerWorkspace,
              canCreateFloatingDockPanel else {
            return nil
        }
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = resolvedTitle?.isEmpty == false
            ? resolvedTitle!
            : Self.defaultFloatingDockTitle(for: initialContent)
        let destinationNoteFileURL = floatingDockNoteFileURL(dockId: id)
        let snapshotNoteFileURL = snapshotManagedNoteFilePath.flatMap {
            WorkspaceFloatingDockNoteStorage.validatedManagedNoteFileURL(path: $0)
        } ?? snapshotWorkspaceStableId.map {
            WorkspaceFloatingDockNoteStorage.fileURL(workspaceStableID: $0, dockID: id)
        }
        let noteFileURL = resolvedManagedNoteFileURL
            ?? WorkspaceFloatingDockNoteStorage.restoredManagedNoteURL(
                source: snapshotNoteFileURL,
                destination: destinationNoteFileURL
            )
        let dock = WorkspaceFloatingDock(
            id: id,
            workspaceId: self.id,
            title: displayTitle,
            frame: Self.sanitizedFloatingDockFrame(frame ?? nextFloatingDockFrame),
            isPresented: isPresented,
            noteFilePath: noteFileURL.path,
            backgroundTintHex: WorkspaceFloatingDockBackgroundColor.normalized(backgroundTintHex),
            initialContent: sessionContent == nil ? initialContent : nil,
            initialURL: initialURL,
            screenFrame: screenFrame,
            displaySnapshot: displaySnapshot,
            configFrames: SessionConfigFrameRing(entries: configFrames ?? []),
            baseDirectoryProvider: { [weak self] in self?.currentDirectory },
            remoteBrowserSettingsProvider: { [weak self] in
                self?.dockRemoteBrowserSettingsSnapshot() ?? .local
            },
            surfaceCreationAllowedProvider: { [weak self] in
                self?.canCreateFloatingDockPanel ?? false
            },
            terminalTransferProvider: { [weak self] command, workingDirectory, environment, tmuxStartCommand in
                guard let self,
                      let pane = self.bonsplitController.focusedPaneId
                        ?? self.bonsplitController.allPaneIds.first,
                      let terminal = self.newTerminalSurface(
                        inPane: pane,
                        focus: false,
                        workingDirectory: workingDirectory,
                        initialCommand: command,
                        tmuxStartCommand: tmuxStartCommand,
                        startupEnvironment: environment,
                        preserveFocusWhenUnfocused: true,
                        allowTextBoxFocusDefault: false
                      ) else { return nil }
                return self.detachSurface(panelId: terminal.id)
            },
            terminalRestoreTransferProvider: { [weak self] panelId, snapshot in
                self?.restoreFloatingDockTerminalTransfer(
                    panelId: panelId,
                    snapshot: snapshot,
                    snapshotWorkspaceId: snapshotWorkspaceId
                )
            }
        )
        guard sessionContent != nil || dock.initialContentWasCreated else {
            dock.close()
            return nil
        }
        if let sessionContent {
            dock.restoreSessionContent(sessionContent)
        }
        floatingDocks.append(dock)
        return dock
    }

    var floatingDockPanelCount: Int {
        floatingDocks.reduce(0) { $0 + $1.store.panels.count }
    }

    var canCreateFloatingDockPanel: Bool {
        floatingDockPanelCount < SessionPersistencePolicy.maxFloatingDockPanelsPerWorkspace
    }

    static var floatingDockSurfaceLimitErrorMessage: String {
        let format = String(
            localized: "floatingDock.error.surfaceLimit",
            defaultValue: "Floating windows can contain at most %lld tabs per workspace."
        )
        return String(
            format: format,
            locale: .current,
            Int64(SessionPersistencePolicy.maxFloatingDockPanelsPerWorkspace)
        )
    }

    func floatingDock(id: UUID) -> WorkspaceFloatingDock? {
        floatingDocks.first(where: { $0.id == id })
    }

    func floatingDock(selector: String?) -> WorkspaceFloatingDock? {
        guard let selector = selector?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selector.isEmpty else {
            return floatingDocks.first
        }
        if let id = UUID(uuidString: selector) {
            return floatingDock(id: id)
        }
        let normalized = selector.lowercased()
        let numeric = normalized.hasPrefix("float:")
            ? Int(normalized.dropFirst("float:".count))
            : Int(normalized)
        guard let numeric, numeric > 0, floatingDocks.indices.contains(numeric - 1) else { return nil }
        return floatingDocks[numeric - 1]
    }

    @discardableResult
    func closeFloatingDock(id: UUID) async -> Bool {
        guard let index = floatingDocks.firstIndex(where: { $0.id == id }) else { return false }
        guard await floatingDocks[index].store.flushPendingAutosavingNotes() else {
            NSSound.beep()
            return false
        }
        return finalizeFloatingDockClose(id: id)
    }

    func finalizeFloatingDockClose(id: UUID) -> Bool {
        guard let index = floatingDocks.firstIndex(where: { $0.id == id }) else { return false }
        let dock = floatingDocks.remove(at: index)
        dock.close()
        return true
    }

    @discardableResult
    func closeAllFloatingDocks() async -> Int? {
        for dock in floatingDocks {
            guard await dock.store.flushPendingAutosavingNotes() else {
                NSSound.beep()
                return nil
            }
        }
        return finalizeAllFloatingDockCloses()
    }

    func finalizeAllFloatingDockCloses() -> Int {
        floatingDockRestoreGeneration &+= 1
        let docks = floatingDocks
        floatingDocks.removeAll(keepingCapacity: true)
        docks.forEach { $0.close() }
        return docks.count
    }

    var needsAutosavingNoteFlush: Bool {
        panels.values.contains { ($0 as? FilePreviewPanel)?.needsAutosaveFlush == true }
            || _dockSplit?.needsAutosavingNoteFlush == true
            || floatingDocks.contains { $0.store.needsAutosavingNoteFlush }
    }

    func flushPendingAutosavingNotes() async -> Bool {
        for panel in panels.values {
            guard let note = panel as? FilePreviewPanel else { continue }
            guard await note.flushPendingAutosave() else { return false }
        }
        if let dock = _dockSplit,
           await dock.flushPendingAutosavingNotes() == false { return false }
        for dock in floatingDocks {
            guard await dock.store.flushPendingAutosavingNotes() else { return false }
        }
        return true
    }

    func floatingDockSessionSnapshots() -> [SessionFloatingDockSnapshot]? {
        var remainingPanelBudget = SessionPersistencePolicy.maxFloatingDockPanelsPerWorkspace
        var snapshots: [SessionFloatingDockSnapshot] = []
        for dock in floatingDocks.prefix(SessionPersistencePolicy.maxFloatingDocksPerWorkspace) {
            guard remainingPanelBudget > 0 else { break }
            let content = dock.sessionContentSnapshot().flatMap {
                Self.boundedFloatingDockContent($0, maximumPanels: remainingPanelBudget)
            }
            let restoredPanelCost = max(1, content?.surfaces.count ?? 0)
            guard restoredPanelCost <= remainingPanelBudget else { break }
            snapshots.append(SessionFloatingDockSnapshot(
                id: dock.id,
                title: dock.title,
                x: dock.frame.origin.x,
                y: dock.frame.origin.y,
                width: dock.frame.width,
                height: dock.frame.height,
                isPresented: dock.isPresented,
                backgroundTintHex: dock.backgroundTintHex,
                managedNoteFilePath: dock.noteFilePath,
                content: content,
                screenFrame: dock.screenFrame.map(SessionRectSnapshot.init),
                display: dock.displaySnapshot,
                configFrames: dock.configFrames.entries.isEmpty ? nil : dock.configFrames.entries
            ))
            remainingPanelBudget -= restoredPanelCost
        }
        return snapshots.isEmpty ? nil : snapshots
    }

    /// Hashes the same bounded projection that session persistence writes so
    /// floating-window-only mutations cannot be skipped by periodic autosave.
    func combineFloatingDocksIntoSessionAutosaveFingerprint(into hasher: inout Hasher) {
        let snapshots = floatingDockSessionSnapshots() ?? []
        hasher.combine(snapshots.count)
        if let encoded = try? JSONEncoder().encode(snapshots) {
            hasher.combine(encoded)
        } else {
            hasher.combine("floating-dock-snapshot-encoding-failed")
        }
    }

    func restoreFloatingDocks(
        from snapshots: [SessionFloatingDockSnapshot]?,
        snapshotWorkspaceId: UUID? = nil,
        snapshotWorkspaceStableId: UUID? = nil
    ) {
        floatingDockRestoreGeneration &+= 1
        let restoreGeneration = floatingDockRestoreGeneration
        floatingDocks.forEach { $0.close() }
        floatingDocks.removeAll()
        var remainingPanelBudget = SessionPersistencePolicy.maxFloatingDockPanelsPerWorkspace
        for snapshot in (snapshots ?? []).prefix(SessionPersistencePolicy.maxFloatingDocksPerWorkspace) {
            guard remainingPanelBudget > 0 else { break }
            let content = snapshot.content.flatMap {
                Self.boundedFloatingDockContent($0, maximumPanels: remainingPanelBudget)
            }
            let restoredPanelCost = max(1, content?.surfaces.count ?? 0)
            guard restoredPanelCost <= remainingPanelBudget else { break }
            remainingPanelBudget -= restoredPanelCost

            let destination = floatingDockNoteFileURL(dockId: snapshot.id)
            let source = snapshot.managedNoteFilePath.flatMap {
                WorkspaceFloatingDockNoteStorage.validatedManagedNoteFileURL(path: $0)
            } ?? snapshotWorkspaceStableId.map {
                WorkspaceFloatingDockNoteStorage.fileURL(workspaceStableID: $0, dockID: snapshot.id)
            }
            let restore: @MainActor (URL) -> Void = { [weak self] noteURL in
                guard let self,
                      self.floatingDockRestoreGeneration == restoreGeneration else { return }
                _ = self.createFloatingDock(
                    id: snapshot.id,
                    title: snapshot.title,
                    frame: CGRect(
                        x: snapshot.x,
                        y: snapshot.y,
                        width: snapshot.width,
                        height: snapshot.height
                    ),
                    isPresented: snapshot.isPresented,
                    backgroundTintHex: snapshot.backgroundTintHex,
                    sessionContent: content,
                    screenFrame: snapshot.screenFrame?.cgRect,
                    displaySnapshot: snapshot.display,
                    configFrames: snapshot.configFrames,
                    resolvedManagedNoteFileURL: noteURL
                )
            }
            if let source,
               source.standardizedFileURL != destination.standardizedFileURL {
                Task { @MainActor in
                    let noteURL = await Task.detached(priority: .utility) {
                        WorkspaceFloatingDockNoteStorage.restoredManagedNoteURL(
                            source: source,
                            destination: destination
                        )
                    }.value
                    restore(noteURL)
                    if let manager = self.owningTabManager {
                        AppDelegate.shared?.refreshWorkspaceFloatingDocks(for: manager)
                    }
                }
            } else {
                restore(destination)
            }
        }
    }

    private static func boundedFloatingDockContent(
        _ snapshot: SessionFloatingDockContentSnapshot,
        maximumPanels: Int
    ) -> SessionFloatingDockContentSnapshot? {
        guard maximumPanels > 0 else { return nil }
        if snapshot.surfaces.isEmpty {
            return SessionFloatingDockContentSnapshot(
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
                surfaces: [],
                focusedPanelId: nil
            )
        }
        var surfacesById: [UUID: SessionFloatingDockSurfaceSnapshot] = [:]
        for surface in snapshot.surfaces where surfacesById[surface.id] == nil {
            surfacesById[surface.id] = surface
        }
        var seenPanelIds: Set<UUID> = []
        let panelIds = Array(
            BonsplitSessionLayoutCodec.orderedPanelIds(in: snapshot.layout)
                .filter { surfacesById[$0] != nil && seenPanelIds.insert($0).inserted }
                .prefix(maximumPanels)
        )
        let persistedPanelIds = Set(panelIds)
        guard !persistedPanelIds.isEmpty,
              let layout = BonsplitSessionLayoutCodec.pruning(
                snapshot.layout,
                keeping: persistedPanelIds
              ) else { return nil }
        return SessionFloatingDockContentSnapshot(
            layout: layout,
            surfaces: panelIds.compactMap { surfacesById[$0] },
            focusedPanelId: snapshot.focusedPanelId.flatMap {
                persistedPanelIds.contains($0) ? $0 : nil
            }
        )
    }

    private func floatingDockNoteFileURL(dockId: UUID) -> URL {
        WorkspaceFloatingDockNoteStorage.fileURL(workspaceStableID: stableId, dockID: dockId)
    }

    var nextFloatingDockFrame: CGRect {
        let cascade = CGFloat(floatingDocks.count % 6) * 24
        return CGRect(x: 36 + cascade, y: 80 - cascade, width: 520, height: 380)
    }

    private static func defaultFloatingDockTitle(for kind: DockSurfaceKind) -> String {
        switch kind {
        case .note:
            String(localized: "floatingDock.defaultTitle", defaultValue: "Notes")
        case .browser:
            String(localized: "floatingDock.defaultBrowserTitle", defaultValue: "Browser")
        case .terminal:
            String(localized: "floatingDock.defaultTerminalTitle", defaultValue: "Terminal")
        }
    }

    static func sanitizedFloatingDockFrame(_ frame: CGRect) -> CGRect {
        let maximumCoordinateMagnitude = CGFloat(
            ControlWorkspaceFloatingDockAction.Frame.maximumCoordinateMagnitude
        )
        let maximumDimension = CGFloat(ControlWorkspaceFloatingDockAction.Frame.maximumDimension)
        let x = frame.origin.x.isFinite
            ? min(max(frame.origin.x, -maximumCoordinateMagnitude), maximumCoordinateMagnitude)
            : 36
        let y = frame.origin.y.isFinite
            ? min(max(frame.origin.y, -maximumCoordinateMagnitude), maximumCoordinateMagnitude)
            : 80
        return CGRect(
            x: x,
            y: y,
            width: min(max(320, frame.width.isFinite ? frame.width : 520), maximumDimension),
            height: min(max(220, frame.height.isFinite ? frame.height : 380), maximumDimension)
        )
    }
}

enum WorkspaceFloatingDockBackgroundColor {
    private static let hexadecimalScalars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6,
              digits.unicodeScalars.allSatisfy({ hexadecimalScalars.contains($0) }) else {
            return nil
        }
        return "#\(digits.uppercased())"
    }
}

enum WorkspaceFloatingDockNoteStorage {
    static func rootDirectory(applicationSupportDirectory: URL? = nil) -> URL {
        let applicationSupport = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("workspace-notes", isDirectory: true)
    }

    static func fileURL(
        workspaceStableID: UUID,
        dockID: UUID,
        applicationSupportDirectory: URL? = nil
    ) -> URL {
        rootDirectory(applicationSupportDirectory: applicationSupportDirectory)
            .appendingPathComponent(workspaceStableID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("\(dockID.uuidString.lowercased()).md")
    }

    static func validatedManagedNoteFileURL(
        path: String,
        rootDirectory: URL = rootDirectory()
    ) -> URL? {
        let root = rootDirectory.standardizedFileURL
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count == rootComponents.count + 2,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents,
              UUID(uuidString: candidateComponents[rootComponents.count]) != nil else { return nil }
        let filename = candidateComponents[rootComponents.count + 1]
        guard (filename as NSString).pathExtension.lowercased() == "md",
              UUID(uuidString: (filename as NSString).deletingPathExtension) != nil else { return nil }
        return candidate
    }

    /// Returns the path the restored Dock must own. Migration failures retain
    /// the validated source path so closed-history restore cannot discard the
    /// user's only note copy.
    static func restoredManagedNoteURL(
        source: URL?,
        destination: URL
    ) -> URL {
        guard let source = source?.standardizedFileURL,
              source != destination.standardizedFileURL else { return destination }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path),
              let sourceValues = try? source.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
              ),
              sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true else { return destination }
        guard !fileManager.fileExists(atPath: destination.path) else { return destination }
        do {
            guard let fileSize = sourceValues.fileSize,
                  fileSize >= 0,
                  UInt64(fileSize) <= FilePreviewTextLoader.maximumLoadedTextBytes else {
                return source
            }
            let data = try Data(contentsOf: source)
            guard UInt64(data.count) <= FilePreviewTextLoader.maximumLoadedTextBytes else {
                return source
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            return source
        }
    }

    static func retainedPaths(in snapshot: AppSessionSnapshot) -> Set<String> {
        snapshot.windows.reduce(into: Set<String>()) { paths, window in
            paths.formUnion(retainedPaths(in: window))
        }
    }

    static func retainedPaths(in window: SessionWindowSnapshot) -> Set<String> {
        window.tabManager.workspaces.reduce(into: Set<String>()) { paths, workspace in
            paths.formUnion(retainedPaths(in: workspace))
        }
    }

    static func retainedPaths(in workspace: SessionWorkspaceSnapshot) -> Set<String> {
        var paths = workspace.panels.reduce(into: Set<String>()) { paths, panel in
            paths.formUnion(retainedPaths(in: panel))
        }
        for dock in workspace.floatingDocks ?? [] {
            if let path = dock.managedNoteFilePath,
               let managedURL = validatedManagedNoteFileURL(path: path) {
                paths.insert(managedURL.path)
            }
            if let stableID = workspace.stableId {
                paths.insert(
                    fileURL(workspaceStableID: stableID, dockID: dock.id)
                        .standardizedFileURL.path
                )
            }
            for surface in dock.content?.surfaces ?? [] {
                if let path = surface.filePreview?.filePath {
                    paths.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
                }
            }
        }
        return paths
    }

    static func retainedPaths(in panel: SessionPanelSnapshot) -> Set<String> {
        guard let path = panel.filePreview?.filePath else { return [] }
        return [URL(fileURLWithPath: path).standardizedFileURL.path]
    }

    static func removeOrphanedFiles(
        retaining retainedPaths: Set<String>,
        rootDirectory: URL = rootDirectory()
    ) {
        let fileManager = FileManager.default
        let root = rootDirectory.standardizedFileURL
        guard let workspaceDirectories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for workspaceDirectory in workspaceDirectories {
            let workspaceValues = try? workspaceDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard UUID(uuidString: workspaceDirectory.lastPathComponent) != nil,
                  workspaceValues?.isDirectory == true,
                  workspaceValues?.isSymbolicLink != true,
                  let files = try? fileManager.contentsOfDirectory(
                    at: workspaceDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }
            for file in files {
                let fileValues = try? file.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard file.pathExtension.lowercased() == "md",
                      UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                      fileValues?.isRegularFile == true,
                      fileValues?.isSymbolicLink != true,
                      !retainedPaths.contains(file.standardizedFileURL.path) else { continue }
                try? fileManager.removeItem(at: file)
            }
            if (try? fileManager.contentsOfDirectory(atPath: workspaceDirectory.path).isEmpty) == true {
                try? fileManager.removeItem(at: workspaceDirectory)
            }
        }
    }

    static func removeOrphanedFilesAfterSessionWrite(
        retaining retainedPaths: Set<String>,
        sessionWriteIsSynchronous: Bool,
        rootDirectory: URL = rootDirectory()
    ) {
        // Asynchronous saves capture retention before they enter the serial
        // persistence queue. A note created in the meantime is authoritative
        // live state but absent from that stale capture, so defer collection to
        // termination, when the main actor is quiescent and the save is inline.
        guard sessionWriteIsSynchronous else { return }
        removeOrphanedFiles(retaining: retainedPaths, rootDirectory: rootDirectory)
    }
}

private enum FloatingDockRestorePlacement {
    case tab(PaneID)
    case split(
        sourcePanelId: UUID,
        orientation: SplitOrientation,
        dividerPosition: CGFloat
    )
}

extension DockSplitStore {
    func floatingDockSessionSnapshot(notePanelId: UUID?) -> SessionFloatingDockContentSnapshot? {
        let rawLayout = BonsplitSessionLayoutCodec.capture(
            controller: bonsplitController,
            panelIdForTab: { [weak self] in self?.surfaceIdToPanelId[$0] }
        )
        let surfaces = BonsplitSessionLayoutCodec.orderedPanelIds(in: rawLayout)
            .prefix(SessionPersistencePolicy.maxPanelsPerWorkspace)
            .compactMap { floatingDockSurfaceSnapshot(panelId: $0, notePanelId: notePanelId) }
        if surfaces.isEmpty {
            return SessionFloatingDockContentSnapshot(
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
                surfaces: [],
                focusedPanelId: nil
            )
        }
        let persistedPanelIds = Set(surfaces.map(\.id))
        guard !surfaces.isEmpty,
              let layout = BonsplitSessionLayoutCodec.pruning(rawLayout, keeping: persistedPanelIds) else {
            return nil
        }
        return SessionFloatingDockContentSnapshot(
            layout: layout,
            surfaces: surfaces,
            focusedPanelId: focusedPanelId.flatMap { persistedPanelIds.contains($0) ? $0 : nil }
        )
    }

    @discardableResult
    func restoreFloatingDockSessionSnapshot(
        _ snapshot: SessionFloatingDockContentSnapshot,
        noteFilePath: String,
        noteTitle: String
    ) -> UUID? {
        resetForSessionRestore()
        guard let rootPane = bonsplitController.allPaneIds.first else { return nil }
        let surfacesById = Dictionary(uniqueKeysWithValues: snapshot.surfaces.map { ($0.id, $0) })
        var restoredPanelIds: [UUID: UUID] = [:]
        restoreFloatingDockLayout(
            snapshot.layout,
            inPane: rootPane,
            seededPanelId: nil,
            surfacesById: surfacesById,
            restoredPanelIds: &restoredPanelIds,
            noteFilePath: noteFilePath,
            noteTitle: noteTitle
        )
        BonsplitSessionLayoutCodec.applyDividerPositions(snapshot.layout, to: bonsplitController)
        if let oldFocusedPanelId = snapshot.focusedPanelId,
           let focusedPanelId = restoredPanelIds[oldFocusedPanelId],
           let pane = paneId(forPanelId: focusedPanelId),
           let tab = surfaceId(forPanelId: focusedPanelId) {
            restoreDockPaneSelection((pane: pane, tab: tab))
        }
        return snapshot.surfaces.first(where: { $0.kind == .note && $0.filePreview == nil })
            .flatMap { restoredPanelIds[$0.id] }
    }

    private func floatingDockSurfaceSnapshot(
        panelId: UUID,
        notePanelId: UUID?
    ) -> SessionFloatingDockSurfaceSnapshot? {
        guard let panel = panels[panelId] else { return nil }
        if panelId == notePanelId {
            return SessionFloatingDockSurfaceSnapshot(id: panelId, kind: .note)
        }
        if let preview = panel as? FilePreviewPanel {
            return SessionFloatingDockSurfaceSnapshot(
                id: panelId,
                kind: .note,
                filePreview: SessionFilePreviewPanelSnapshot(
                    filePath: preview.filePath,
                    noteTitle: preview.presentation.noteTitle
                )
            )
        }
        if let terminal = panel as? TerminalPanel {
            let transfer = detachedSurfaceTransfersByPanelId[panelId]
            let agent = terminal.agentHibernationState?.agent ?? transfer?.restorableAgent
            let shellActivity = terminal.shellActivity.state == .unknown
                ? transfer?.shellActivityState
                : terminal.shellActivity.state
            let wasAgentRunning: Bool? = switch shellActivity {
            case .some(.commandRunning): true
            case .some(.promptIdle): false
            case .some(.unknown), .none: nil
            }
            return SessionFloatingDockSurfaceSnapshot(
                id: panelId,
                kind: .terminal,
                terminal: SessionTerminalPanelSnapshot(
                    workingDirectory: transfer?.directory ?? terminal.requestedWorkingDirectory,
                    agent: agent,
                    tmuxStartCommand: agent == nil ? terminal.surface.debugTmuxStartCommand() : nil,
                    hibernation: terminal.agentHibernationState.map {
                        SessionAgentHibernationSnapshot(
                            hibernatedAt: $0.hibernatedAt.timeIntervalSince1970,
                            lastActivityAt: $0.lastActivityAt.timeIntervalSince1970
                        )
                    },
                    resumeBinding: transfer?.resumeBinding,
                    textBoxDraft: terminal.sessionTextBoxDraftSnapshot(),
                    isRemoteTerminal: transfer?.isRemoteTerminal,
                    remotePTYSessionID: transfer?.remotePTYSessionID,
                    wasAgentRunning: agent == nil ? nil : wasAgentRunning
                )
            )
        }
        if let browser = panel as? BrowserPanel, browser.shouldPersistSessionSnapshot() {
            return SessionFloatingDockSurfaceSnapshot(
                id: panelId,
                kind: .browser,
                browser: browser.sessionPersistenceSnapshot()
            )
        }
        return nil
    }

    private func restoreFloatingDockLayout(
        _ node: SessionWorkspaceLayoutSnapshot,
        inPane pane: PaneID,
        seededPanelId: UUID?,
        surfacesById: [UUID: SessionFloatingDockSurfaceSnapshot],
        restoredPanelIds: inout [UUID: UUID],
        noteFilePath: String,
        noteTitle: String
    ) {
        switch node {
        case .pane(let paneSnapshot):
            for oldPanelId in paneSnapshot.panelIds where oldPanelId != seededPanelId {
                guard let surface = surfacesById[oldPanelId],
                      let newPanelId = restoreFloatingDockSurface(
                        surface,
                        placement: .tab(pane),
                        noteFilePath: noteFilePath,
                        noteTitle: noteTitle
                      ) else { continue }
                restoredPanelIds[oldPanelId] = newPanelId
            }
            if let selectedOldPanelId = paneSnapshot.selectedPanelId,
               let selectedPanelId = restoredPanelIds[selectedOldPanelId],
               let tab = surfaceId(forPanelId: selectedPanelId) {
                bonsplitController.focusPane(pane)
                bonsplitController.selectTab(tab)
            }
            if paneSnapshot.isFullWidthTabMode == true {
                _ = bonsplitController.setFullWidthTabMode(true, inPane: pane)
            }
        case .split(let split):
            guard let firstOldPanelId = firstRestorableFloatingDockPanelId(
                in: split.first,
                surfacesById: surfacesById
            ) else { return }
            let firstPanelId: UUID
            if let seededPanelId, let restored = restoredPanelIds[seededPanelId] {
                firstPanelId = restored
            } else {
                guard let surface = surfacesById[firstOldPanelId],
                      let restored = restoreFloatingDockSurface(
                        surface,
                        placement: .tab(pane),
                        noteFilePath: noteFilePath,
                        noteTitle: noteTitle
                      ) else { return }
                restoredPanelIds[firstOldPanelId] = restored
                firstPanelId = restored
            }
            guard let secondOldPanelId = firstRestorableFloatingDockPanelId(
                in: split.second,
                surfacesById: surfacesById
            ),
                  let secondSurface = surfacesById[secondOldPanelId],
                  let secondPanelId = restoreFloatingDockSurface(
                    secondSurface,
                    placement: .split(
                        sourcePanelId: firstPanelId,
                        orientation: split.orientation.splitOrientation,
                        dividerPosition: CGFloat(split.dividerPosition)
                    ),
                    noteFilePath: noteFilePath,
                    noteTitle: noteTitle
                  ),
                  let secondPane = paneId(forPanelId: secondPanelId) else { return }
            restoredPanelIds[secondOldPanelId] = secondPanelId
            restoreFloatingDockLayout(
                split.first,
                inPane: pane,
                seededPanelId: firstOldPanelId,
                surfacesById: surfacesById,
                restoredPanelIds: &restoredPanelIds,
                noteFilePath: noteFilePath,
                noteTitle: noteTitle
            )
            restoreFloatingDockLayout(
                split.second,
                inPane: secondPane,
                seededPanelId: secondOldPanelId,
                surfacesById: surfacesById,
                restoredPanelIds: &restoredPanelIds,
                noteFilePath: noteFilePath,
                noteTitle: noteTitle
            )
        }
    }

    private func firstRestorableFloatingDockPanelId(
        in node: SessionWorkspaceLayoutSnapshot,
        surfacesById: [UUID: SessionFloatingDockSurfaceSnapshot]
    ) -> UUID? {
        BonsplitSessionLayoutCodec.orderedPanelIds(in: node).first { surfacesById[$0] != nil }
    }

    private func restoreFloatingDockSurface(
        _ snapshot: SessionFloatingDockSurfaceSnapshot,
        placement: FloatingDockRestorePlacement,
        noteFilePath: String,
        noteTitle: String
    ) -> UUID? {
        if let filePreview = snapshot.filePreview {
            return restoreFloatingDockFilePreview(filePreview, placement: placement)
        }
        if snapshot.kind == .terminal,
           let terminalSnapshot = snapshot.terminal,
           let terminalRestoreTransferProvider {
            guard let transfer = terminalRestoreTransferProvider(snapshot.id, terminalSnapshot) else {
                return nil
            }
            let restoredPanelId: UUID?
            switch placement {
            case .tab(let pane):
                restoredPanelId = attachDetachedSurface(transfer, inPane: pane, focus: false)
            case .split(let sourcePanelId, let orientation, let dividerPosition):
                guard let sourcePane = paneId(forPanelId: sourcePanelId) else {
                    transfer.panel.close()
                    return nil
                }
                restoredPanelId = attachDetachedSurface(
                    transfer,
                    bySplitting: sourcePane,
                    orientation: orientation,
                    insertFirst: false,
                    initialDividerPosition: dividerPosition,
                    focus: false
                )
            }
            guard let restoredPanelId else {
                transfer.panel.close()
                return nil
            }
            return restoredPanelId
        }
        let workingDirectory = snapshot.terminal?.workingDirectory
        let panelId: UUID?
        switch placement {
        case .tab(let pane):
            panelId = newSurface(
                kind: snapshot.kind,
                inPane: pane,
                url: nil,
                workingDirectory: workingDirectory,
                tmuxStartCommand: snapshot.terminal?.tmuxStartCommand,
                noteFilePath: snapshot.kind == .note ? noteFilePath : nil,
                noteTitle: snapshot.kind == .note ? noteTitle : nil,
                focus: false,
                preferredProfileID: snapshot.browser?.profileID
            )
        case .split(let sourcePanelId, let orientation, let dividerPosition):
            panelId = newSplit(
                kind: snapshot.kind,
                orientation: orientation,
                insertFirst: false,
                sourcePanelId: sourcePanelId,
                url: nil,
                workingDirectory: workingDirectory,
                tmuxStartCommand: snapshot.terminal?.tmuxStartCommand,
                noteFilePath: snapshot.kind == .note ? noteFilePath : nil,
                noteTitle: snapshot.kind == .note ? noteTitle : nil,
                preferredProfileID: snapshot.browser?.profileID,
                initialDividerPosition: dividerPosition,
                focus: false
            )
        }
        guard let panelId else { return nil }
        if let browserSnapshot = snapshot.browser,
           let browser = panels[panelId] as? BrowserPanel {
            browser.restoreCompleteSessionSnapshot(browserSnapshot)
        }
        if let terminalSnapshot = snapshot.terminal,
           let terminal = panels[panelId] as? TerminalPanel {
            terminal.restoreSessionTextBoxDraft(terminalSnapshot.textBoxDraft)
        }
        return panelId
    }

    private func restoreFloatingDockFilePreview(
        _ snapshot: SessionFilePreviewPanelSnapshot,
        placement: FloatingDockRestorePlacement
    ) -> UUID? {
        let presentation: FilePreviewPresentation = snapshot.noteTitle.map { .note(title: $0) } ?? .file
        let panel = WorkspaceFloatingDockNoteWriter.makeFilePreviewPanel(
            workspaceId: workspaceId,
            filePath: snapshot.filePath,
            presentation: presentation
        )
        switch placement {
        case .tab(let pane):
            guard attachPanelAsTab(
                panel,
                kind: .note,
                title: panel.displayTitle,
                inPane: pane,
                tracksTerminalTitle: false
            ) != nil else { return nil }
        case .split(let sourcePanelId, let orientation, let dividerPosition):
            guard let sourcePane = paneId(forPanelId: sourcePanelId) else { return nil }
            panels[panel.id] = panel
            let tab = Bonsplit.Tab(
                title: panel.displayTitle,
                icon: panel.displayIcon,
                kind: "filepreview",
                isDirty: panel.isDirty,
                isPinned: false
            )
            surfaceIdToPanelId[tab.id] = panel.id
            guard withProgrammaticDockSplit({
                bonsplitController.splitPane(
                    sourcePane,
                    orientation: orientation,
                    withTab: tab,
                    insertFirst: false,
                    initialDividerPosition: dividerPosition
                )
            }) != nil else {
                surfaceIdToPanelId.removeValue(forKey: tab.id)
                panels.removeValue(forKey: panel.id)
                panel.close()
                return nil
            }
            installSubscription(for: panel, tracksTerminalTitle: false)
            applyVisibility(to: panel)
        }
        WorkspaceFloatingDockNoteOwnerRegistry.register(panel)
        return panel.id
    }
}
