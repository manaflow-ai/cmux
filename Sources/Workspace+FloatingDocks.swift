import CoreGraphics
import Foundation

extension Workspace {
    /// Creates a workspace-scoped floating Dock with a native autosaving note.
    @discardableResult
    func createFloatingDock(
        id: UUID = UUID(),
        title: String? = nil,
        frame: CGRect = CGRect(x: 36, y: 80, width: 520, height: 380),
        isPresented: Bool = true,
        configurationSeedIdentity: String? = nil,
        configurationContent: DockControlDefinition? = nil,
        configurationBaseDirectory: String? = nil
    ) -> WorkspaceFloatingDock? {
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = resolvedTitle?.isEmpty == false
            ? resolvedTitle!
            : String(localized: "floatingDock.defaultTitle", defaultValue: "Notes")
        guard let noteFileURL = floatingDockNoteFileURL(dockId: id) else { return nil }
        let existingNotePanel = panels.values
            .compactMap { $0 as? FilePreviewPanel }
            .first { panel in
                panel.presentation.autosavesTextChanges &&
                    URL(fileURLWithPath: panel.filePath).standardizedFileURL == noteFileURL.standardizedFileURL
            }
        let dock = WorkspaceFloatingDock(
            id: id,
            workspaceId: self.id,
            title: displayTitle,
            frame: Self.sanitizedFloatingDockFrame(frame),
            isPresented: isPresented,
            noteFilePath: noteFileURL.path,
            existingNotePanelId: existingNotePanel?.id,
            configurationSeedIdentity: configurationSeedIdentity,
            configurationContent: configurationContent,
            configurationBaseDirectory: configurationBaseDirectory,
            baseDirectoryProvider: { [weak self] in self?.currentDirectory },
            remoteBrowserSettingsProvider: { [weak self] in
                self?.dockRemoteBrowserSettingsSnapshot() ?? .local
            }
        )
        floatingDocks.append(dock)
        return dock
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
    func closeFloatingDock(id: UUID) -> Bool {
        guard let index = floatingDocks.firstIndex(where: { $0.id == id }) else { return false }
        let dock = floatingDocks.remove(at: index)
        dock.close()
        return true
    }

    func floatingDockSessionSnapshots() -> [SessionFloatingDockSnapshot]? {
        let snapshots = floatingDocks.map { dock in
            SessionFloatingDockSnapshot(
                id: dock.id,
                title: dock.title,
                x: dock.frame.origin.x,
                y: dock.frame.origin.y,
                width: dock.frame.width,
                height: dock.frame.height,
                isPresented: dock.isPresented,
                configurationSeedIdentity: dock.configurationSeedIdentity,
                configurationContent: dock.configurationContent,
                configurationBaseDirectory: dock.configurationBaseDirectory
            )
        }
        return snapshots.isEmpty ? nil : snapshots
    }

    func restoreFloatingDocks(
        from snapshots: [SessionFloatingDockSnapshot]?,
        seededConfigurationIdentities: [String]?
    ) {
        floatingDocks.forEach { $0.close() }
        floatingDocks.removeAll()
        seededFloatingDockConfigurationIdentities = Set(seededConfigurationIdentities ?? [])
        seededFloatingDockConfigurationIdentities.formUnion(
            (snapshots ?? []).compactMap(\.configurationSeedIdentity)
        )
        for snapshot in snapshots ?? [] {
            _ = createFloatingDock(
                id: snapshot.id,
                title: snapshot.title,
                frame: CGRect(
                    x: snapshot.x,
                    y: snapshot.y,
                    width: snapshot.width,
                    height: snapshot.height
                ),
                isPresented: snapshot.isPresented,
                configurationSeedIdentity: snapshot.configurationSeedIdentity,
                configurationContent: snapshot.configurationContent,
                configurationBaseDirectory: snapshot.configurationBaseDirectory
            )
        }
    }

    private func floatingDockNoteFileURL(dockId: UUID) -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = applicationSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("workspace-notes", isDirectory: true)
            .appendingPathComponent(stableId.uuidString.lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("\(dockId.uuidString.lowercased()).md")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL, options: .atomic)
            }
            return fileURL
        } catch {
            cmuxDebugLog("floatingDock.noteFile.error workspace=\(id) dock=\(dockId) error=\(error)")
            return nil
        }
    }

    private static func sanitizedFloatingDockFrame(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.origin.x.isFinite ? frame.origin.x : 36,
            y: frame.origin.y.isFinite ? frame.origin.y : 80,
            width: max(320, frame.width.isFinite ? frame.width : 520),
            height: max(220, frame.height.isFinite ? frame.height : 380)
        )
    }
}
