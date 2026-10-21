import CmuxNextFiles
import Foundation
import Observation

/// The right sidebar's file explorer (classic's Files mode): a folder tree
/// rooted at the focused terminal's folder, folders first, hidden items left
/// out, with one selected row. Listing runs off the main actor through the
/// injected ``DirectoryListing``, so tests drive it against a temp folder.
@MainActor
@Observable
final class FileExplorerModel {
    /// The folder the tree shows; nil before the first ``setRoot(_:)``.
    private(set) var root: URL?
    /// The visible rows, in display order.
    private(set) var rows: [FileExplorerRow] = []
    /// The selected row's item.
    var selection: URL?
    /// The root could not be read (the system's message); nil while it lists.
    private(set) var failure: String?

    @ObservationIgnored private let lister: any DirectoryListing
    @ObservationIgnored private var children: [URL: [FileEntry]] = [:]
    @ObservationIgnored private var expanded: Set<URL> = []
    @ObservationIgnored private var generation = 0

    init(lister: any DirectoryListing = DirectoryLister()) {
        self.lister = lister
    }

    /// Shows the tree of `folder`; the same folder only re-reads it.
    func setRoot(_ folder: URL) async {
        let folder = folder.standardizedFileURL
        if folder != root {
            root = folder
            children = [:]
            expanded = []
            selection = nil
        }
        await reload()
    }

    /// Lists the root and every expanded folder again (the folder may have changed since).
    func reload() async {
        guard let root else { return }
        generation += 1
        let mine = generation
        var listed: [URL: [FileEntry]] = [:]
        do {
            listed[root] = try await lister.list(root)
        } catch {
            guard mine == generation else { return }
            failure = error.localizedDescription
            children = [:]
            rows = []
            return
        }
        for folder in expanded { listed[folder] = (try? await lister.list(folder)) ?? [] }
        guard mine == generation else { return }
        failure = nil
        children = listed
        rebuild()
    }

    /// Expands a collapsed folder (listing it) or collapses an expanded one.
    func toggle(_ folder: URL) async {
        if expanded.remove(folder) != nil {
            rebuild()
            return
        }
        let entries = (try? await lister.list(folder)) ?? []
        expanded.insert(folder)
        children[folder] = entries
        rebuild()
    }

    /// The row of `url`, if it shows.
    func row(_ url: URL) -> FileExplorerRow? { rows.first { $0.url == url } }

    /// The selected row, if it still shows.
    var selectedRow: FileExplorerRow? { selection.flatMap(row) }

    /// `url`'s path under the root ("Sources/App.swift"); the full path outside it.
    func relativePath(of url: URL) -> String {
        guard let root else { return url.path }
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
    }

    private func rebuild() {
        guard let root else { rows = []; return }
        var out: [FileExplorerRow] = []
        func add(_ folder: URL, depth: Int) {
            for entry in Self.sorted(children[folder] ?? []) {
                let url = entry.url.standardizedFileURL
                let isFolder = entry.kind == .folder
                let open = isFolder && expanded.contains(url)
                out.append(FileExplorerRow(url: url, name: entry.name, depth: depth, isFolder: isFolder, isExpanded: open))
                if open { add(url, depth: depth + 1) }
            }
        }
        add(root, depth: 0)
        rows = out
    }

    /// Folders first, then by name as Finder sorts; hidden items left out.
    private static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.filter { !$0.isHidden }.sorted { lhs, rhs in
            let lhsFolder = lhs.kind == .folder, rhsFolder = rhs.kind == .folder
            if lhsFolder != rhsFolder { return lhsFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
