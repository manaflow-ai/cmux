import AppKit
import CmuxNextFiles

/// Get Info, Rename Items, Make Alias, Compress / Expand, Delete Immediately,
/// Show Package Contents, the Go menu places and the sidebar.
extension FilesPaneView {
    /// Get Info (Cmd+I): one window per selected item (the folder when none).
    func getInfo() {
        let urls = model.selectedEntries.isEmpty ? [model.folder] : model.selectedEntries.map(\.url)
        for url in urls {
            if let open = infoWindows[url] {
                open.panel.makeKeyAndOrderFront(nil)
                continue
            }
            let window = FileInfoWindow(url: url, icon: NSWorkspace.shared.icon(forFile: url.path)) { [weak self] in
                self?.infoWindows[url] = nil
            }
            infoWindows[url] = window
            window.show()
        }
    }

    /// Rename (Return, menu): inline for one item, the Rename Items sheet for several.
    func renameSelectionOrItems() {
        guard model.selection.count > 1 else {
            renameSelection()
            return
        }
        let names = model.selectedEntries.map(\.name)
        Task {
            guard let rename = await prompts.batchRename(names) else { return }
            await model.batchRename(rename)
            if model.lastError != nil { NSSound.beep() }
        }
    }

    func makeAlias(_ kind: LinkKind) { Task { await model.makeAliasesOfSelection(kind: kind) } }
    func compress() { Task { await model.compressSelection(archiveName: FilesStrings.archiveName) } }

    func expandSelection() {
        let archives = model.selectedEntries.filter { $0.name.lowercased().hasSuffix(".zip") }.map(\.url)
        Task { for archive in archives { await model.expand(archive) } }
    }

    /// Delete Immediately (Opt+Cmd+Delete), after a confirmation.
    func deleteImmediately() {
        let count = model.selection.count
        guard count > 0 else { return }
        Task {
            guard await prompts.confirmDelete(count) else { return }
            await model.deleteSelectionImmediately()
        }
    }

    /// Show Package Contents: opens a package as a folder.
    func showPackageContents() {
        guard let entry = model.selectedEntries.first, entry.kind == .package else { return }
        Task { await model.open(entry.url) }
    }

    /// The Go menu: Shift+Cmd+H, D, O, L, A, U, C, I.
    func go(to place: GoPlace) {
        Task { await model.open(place.url(home: home)) }
    }

    /// Show / Hide Sidebar (Ctrl+Cmd+S).
    func toggleSidebar() { sidebar.isVisible.toggle() }

    func makeSidebarActions() -> FileSidebarActions {
        FileSidebarActions(
            open: { [weak self] url in Task { await self?.model.open(url) } },
            add: { [weak self] url, index in self?.sidebar.addFavorite(url, at: index) },
            remove: { [weak self] url in self?.sidebar.removeFavorite(url) },
            eject: { [weak self] volume in self?.eject(volume) },
            drop: { [weak self] urls, folder, option, command in
                self?.dropFromSidebar(urls, into: folder, option: option, command: command)
            }
        )
    }

    private func eject(_ volume: SidebarVolume) {
        Task { [weak self] in
            do {
                try await FileManager.default.unmountVolume(at: volume.url, options: [.allPartitionsAndEjectDisk])
            } catch {
                NSSound.beep()
            }
            await self?.sidebar.refreshLocations()
        }
    }

    private func dropFromSidebar(_ urls: [URL], into folder: URL, option: Bool, command: Bool) {
        let mode = DropPolicy().mode(for: urls, into: folder, option: option, command: command)
        let prompts = self.prompts
        Task {
            await model.transfer(urls, into: folder, mode: mode, resolve: { conflict in await prompts.conflict(conflict) })
        }
    }
}
