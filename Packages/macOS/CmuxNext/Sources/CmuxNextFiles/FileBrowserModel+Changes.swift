public import Foundation

/// Files changes with Undo: rename, new folder, duplicate, trash, copy and move.
extension FileBrowserModel {
    /// Renames `url` to `name`. Records Undo. Returns the new URL, or nil on failure (see ``lastError``).
    @discardableResult
    public func rename(_ url: URL, to name: String) async -> URL? {
        await record {
            let renamed = try await files.rename(url, to: name)
            guard renamed != url else { return nil }
            await refreshNow()
            select(renamed)
            return .moved([.init(from: url, to: renamed)])
        }
    }

    /// New Folder (Shift+Cmd+N) in the current folder; selects it. Returns its URL.
    @discardableResult
    public func newFolder(named name: String) async -> URL? {
        var made: URL?
        _ = await record {
            let url = try await files.newFolder(in: folder, named: name)
            made = url
            await refreshNow()
            select(url)
            return .created([url])
        }
        return made
    }

    /// Duplicate (Cmd+D) the selection; selects the copies.
    public func duplicateSelection() async {
        let sources = selectedEntries.map(\.url)
        guard !sources.isEmpty else { return }
        _ = await record {
            let copies = try await files.duplicate(sources)
            await refreshNow()
            selection = Set(copies.map(\.lastPathComponent))
            cursor = copies.last?.lastPathComponent
            return .created(copies)
        }
    }

    /// Move to Trash (Cmd+Delete) the selection; Undo puts it back.
    public func trashSelection() async {
        let sources = selectedEntries.map(\.url)
        guard !sources.isEmpty else { return }
        _ = await record {
            let trashed = try await files.trash(sources)
            await refreshNow()
            return .trashed(trashed)
        }
    }

    /// Copies or moves `sources` into `destination` (default: the current
    /// folder), asking `resolve` about taken names. Records Undo.
    public func transfer(_ sources: [URL], into destination: URL? = nil, mode: TransferMode,
                         resolve: @escaping @Sendable (FileConflict) async -> ConflictAnswer) async {
        let target = destination ?? folder
        _ = await record {
            var placed: [URL: URL] = [:]
            for try await event in files.transfer(sources, to: target, mode: mode, resolve: resolve) {
                switch event {
                case .progress(let progress): transferProgress = progress
                case .finished(let done, _): placed = done
                }
            }
            transferProgress = nil
            await refreshNow()
            if target == folder { selection = Set(placed.values.map(\.lastPathComponent)) }
            guard !placed.isEmpty else { return nil }
            switch mode {
            case .copy: return .created(Array(placed.values))
            case .move: return .moved(placed.map { .init(from: $0.key, to: $0.value) })
            }
        }
        transferProgress = nil
    }

    /// Undo (Cmd+Z): reverses the last change.
    public func undo() async {
        guard let action = undoStack.popLast() else { return }
        do {
            let inverse = try await reverse(action)
            redoStack.append(inverse)
            lastError = nil
        } catch {
            lastError = Self.wrap(error)
        }
        await refreshNow()
    }

    /// Redo (Shift+Cmd+Z): makes the last undone change again.
    public func redo() async {
        guard let action = redoStack.popLast() else { return }
        do {
            let inverse = try await reverse(action)
            undoStack.append(inverse)
            lastError = nil
        } catch {
            lastError = Self.wrap(error)
        }
        await refreshNow()
    }

    /// Runs `body`, records the Undo it returns, and keeps its error.
    func record(_ body: () async throws -> FileUndoAction?) async -> URL? {
        do {
            let action = try await body()
            lastError = nil
            if let action {
                undoStack.append(action)
                redoStack.removeAll()
                if case .moved(let items) = action { return items.first?.to }
            }
        } catch {
            lastError = Self.wrap(error)
            await refreshNow()
        }
        return nil
    }

    /// Does the opposite of `action`, and returns the action that would undo that.
    func reverse(_ action: FileUndoAction) async throws -> FileUndoAction {
        switch action {
        case .moved(let items):
            try await files.move(items.map { (from: $0.to, to: $0.from) })
            return .moved(items.map { .init(from: $0.to, to: $0.from) })
        case .created(let urls):
            return .trashed(try await files.trash(urls))
        case .trashed(let items):
            return .created(try await files.putBack(items))
        }
    }

    /// Lists again now (a change made here should not wait for FSEvents).
    func refreshNow() async {
        guard let listed = try? await Self.listSorted(folder, lister: lister, order: sortOrder) else { return }
        all = listed
        refilter()
    }

}
