public import Foundation

/// Rename Items, Make Alias, Compress / Expand, Delete Immediately and Tab selection.
extension FileBrowserModel {
    /// Rename Items… on the selection, in display order. Nothing changes when any
    /// new name has a problem (``lastError`` says which). Records one Undo.
    public func batchRename(_ rename: BatchRename) async {
        let names = selectedEntries.map(\.name)
        guard !names.isEmpty else { return }
        let plan = rename.plan(names, taken: Set(all.map(\.name)))
        if let bad = plan.first(where: { $0.problem != nil }) {
            lastError = switch bad.problem {
            case .invalid?: .invalidName(bad.to)
            case .numberTooLarge?: .renameNumberTooLarge
            case .duplicate?, .exists?, nil: .exists(folder.appendingPathComponent(bad.to))
            }
            return
        }
        let changed = plan.filter(\.changes)
        guard !changed.isEmpty else { return }
        let pairs = changed.map { (from: folder.appendingPathComponent($0.from), to: folder.appendingPathComponent($0.to)) }
        _ = await record {
            try await files.move(pairs)
            await refreshNow()
            selection = Set(plan.map(\.to))
            cursor = plan.last?.to
            return .moved(pairs.map { .init(from: $0.from, to: $0.to) })
        }
    }

    /// Make Alias (Ctrl+Cmd+A) of the selection; selects the new items.
    public func makeAliasesOfSelection(kind: LinkKind) async {
        let sources = selectedEntries.map(\.url)
        guard !sources.isEmpty else { return }
        _ = await record {
            let made = try await files.makeLinks(sources, kind: kind)
            await refreshNow()
            selectMade(made)
            return .created(made)
        }
    }

    /// Compress the selection; selects the archive. Undo trashes it.
    public func compressSelection(archiveName: String) async {
        let sources = selectedEntries.map(\.url)
        guard !sources.isEmpty else { return }
        _ = await record {
            let archive = try await files.compress(sources, archiveName: archiveName)
            await refreshNow()
            selectMade([archive])
            return .created([archive])
        }
    }

    /// Expands `archive` beside itself; selects what came out. Undo trashes it.
    public func expand(_ archive: URL) async {
        _ = await record {
            let made = try await files.expand(archive)
            await refreshNow()
            selectMade([made])
            return .created([made])
        }
    }

    /// Delete Immediately (Opt+Cmd+Delete) the selection. It cannot be undone,
    /// and Redo is cleared (it might name what is now gone).
    public func deleteSelectionImmediately() async {
        let sources = selectedEntries.map(\.url)
        guard !sources.isEmpty else { return }
        _ = await record {
            try await files.deleteImmediately(sources)
            redoStack.removeAll()
            selection = []
            await refreshNow()
            return nil
        }
    }

    /// Tab / Shift+Tab: selects the next (or previous) name in alphabetical
    /// order, whatever the sort; wraps at the ends.
    public func selectAlphabetically(forward: Bool) {
        let sorted = entries.sorted { $0.sortKey < $1.sortKey }
        guard !sorted.isEmpty else { return }
        let next: FileEntry
        if let cursor, let at = sorted.firstIndex(where: { $0.name == cursor }) {
            next = sorted[(at + (forward ? 1 : sorted.count - 1)) % sorted.count]
        } else {
            next = forward ? sorted[0] : sorted[sorted.count - 1]
        }
        select(next.name)
    }

    private func selectMade(_ urls: [URL]) {
        let here = urls.filter { $0.deletingLastPathComponent().standardizedFileURL == folder }
        selection = Set(here.map(\.lastPathComponent))
        cursor = here.last?.lastPathComponent
    }
}
