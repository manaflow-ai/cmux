public import CmuxNextWakeups
public import Foundation
import Observation

/// One Files pane's state: the folder shown, its sorted and filtered items,
/// the selection, history, view options and undo.
///
/// Listing and sorting run off the main actor (``DirectoryListing``); live
/// changes arrive through ``FolderWatching`` and update single rows: each
/// change is read off main and its rows land as one visible task on the app's
/// ``MainWorkScheduler``. Every dependency comes through `init`, so tests drive
/// the model against a temp folder or fakes:
///
/// ```swift
/// let model = FileBrowserModel(folder: tempFolder, work: mainWork)
/// await model.reload()
/// model.select(model.entries[0].url)
/// try await model.trashSelection()
/// try await model.undo() // the item is back
/// ```
@MainActor
@Observable
public final class FileBrowserModel {
    /// Where the listing is.
    public enum Phase: Sendable, Equatable {
        /// The folder is being read.
        case loading
        /// ``entries`` shows the folder.
        case ready
        /// The folder could not be read (the system's message).
        case failed(String)
    }

    /// The folder shown.
    public private(set) var folder: URL
    /// The items shown: sorted, hidden ones only when ``showHidden``, filtered by ``filterText``.
    public private(set) var entries: [FileEntry] = []
    /// Loading, ready or failed.
    public internal(set) var phase: Phase = .loading
    /// Names of the selected items (names are unique in one folder).
    public var selection: Set<String> = []
    /// The name of the item keyboard moves start from (the last clicked or moved to).
    public internal(set) var cursor: String?
    /// The order of ``entries``. Changing it sorts again.
    public var sortOrder: FileSortOrder { didSet { if oldValue != sortOrder { resort(); rememberView() } } }
    /// Show dot files and `UF_HIDDEN` items (Cmd+Shift+.).
    public var showHidden: Bool { didSet { if oldValue != showHidden { refilter() } } }
    /// Only names containing this (case- and accent-insensitive) show; empty shows all.
    public var filterText: String = "" { didSet { if oldValue != filterText { refilter() } } }
    /// Icons, list or columns.
    public var viewMode: FileViewMode { didSet { if oldValue != viewMode { rememberView() } } }
    /// The last operation's failure, for the pane to show; nil after a success.
    public internal(set) var lastError: FileBrowserError?
    /// A running copy or move.
    public internal(set) var transferProgress: TransferProgress?
    /// The listing's wall time of the last load, in milliseconds (perf panel and tests).
    public private(set) var lastLoadMilliseconds: Double = 0

    /// Whether Back has somewhere to go.
    public var canGoBack: Bool { !backStack.isEmpty }
    /// Whether Forward has somewhere to go.
    public var canGoForward: Bool { !forwardStack.isEmpty }
    /// Whether Enclosing Folder has somewhere to go.
    public var canGoUp: Bool { folder.path != "/" }
    /// Whether Undo has something to undo.
    public var canUndo: Bool { !undoStack.isEmpty }
    /// Whether Redo has something to redo.
    public var canRedo: Bool { !redoStack.isEmpty }
    /// The selected entries in display order.
    public var selectedEntries: [FileEntry] { entries.filter { selection.contains($0.name) } }

    @ObservationIgnored var all: [FileEntry] = []
    @ObservationIgnored private var backStack: [URL] = []
    @ObservationIgnored private var forwardStack: [URL] = []
    @ObservationIgnored var undoStack: [FileUndoAction] = []
    @ObservationIgnored var redoStack: [FileUndoAction] = []
    /// Bumped by every listing: a watched change or a re-sort of an older one applies nothing.
    @ObservationIgnored private(set) var generation = 0
    /// The current folder's watch (`FileBrowserModel+Watch.swift`).
    @ObservationIgnored var watchTask: Task<Void, Never>?
    @ObservationIgnored private var typeSelect = TypeSelectBuffer()
    @ObservationIgnored private var indexCache: [String: Int]?
    @ObservationIgnored let lister: any DirectoryListing
    @ObservationIgnored let watcher: any FolderWatching
    @ObservationIgnored let files: any FileOperating
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let resolver: GoToFolderResolver
    @ObservationIgnored private let memory: FolderViewMemory?
    /// Where each watched change's rows land (a visible task: the pane shows them; no action of the person caused them).
    @ObservationIgnored let work: MainWorkScheduler

    /// Makes a model on `folder`; call ``reload()`` (or ``open(_:)``) to list it.
    /// - Parameters:
    ///   - folder: The first folder.
    ///   - work: The app's main-thread scheduler (`AppServices.mainWork`), where watched changes land.
    ///   - viewMode: The first layout. Defaults to list.
    ///   - sortOrder: The first order. Defaults to Finder's (name, ascending).
    ///   - showHidden: Show hidden items. Defaults to false.
    ///   - lister: Reads folders. Defaults to ``DirectoryLister``.
    ///   - watcher: Reports changes. Defaults to ``FolderWatcher``.
    ///   - files: Makes changes. Defaults to ``FileOperator``.
    ///   - resolver: Resolves Go to Folder text. Defaults to the real file system.
    ///   - now: The clock type-select reads (a seam for tests).
    ///   - memory: Each folder's remembered view and order; nil keeps one for all.
    public init(folder: URL, work: MainWorkScheduler, viewMode: FileViewMode = .list, sortOrder: FileSortOrder = FileSortOrder(),
                showHidden: Bool = false, lister: any DirectoryListing = DirectoryLister(),
                watcher: any FolderWatching = FolderWatcher(), files: any FileOperating = FileOperator(),
                resolver: GoToFolderResolver = GoToFolderResolver(), now: @escaping @Sendable () -> Date = { Date() },
                memory: FolderViewMemory? = nil) {
        self.folder = folder.standardizedFileURL
        self.work = work
        self.viewMode = viewMode
        self.sortOrder = sortOrder
        self.showHidden = showHidden
        self.lister = lister
        self.watcher = watcher
        self.files = files
        self.resolver = resolver
        self.now = now
        self.memory = memory
        if let prefs = memory?.prefs(for: self.folder) {
            self.viewMode = prefs.viewMode
            self.sortOrder = prefs.sortOrder
        }
    }

    // MARK: Navigation

    /// Shows `folder`, adding the current one to Back. `select` picks an item in it.
    public func open(_ folder: URL, select: URL? = nil) async {
        let target = folder.standardizedFileURL
        guard target != self.folder || phase != .ready else {
            if let select { self.select(select) }
            return
        }
        backStack.append(self.folder)
        forwardStack.removeAll()
        await show(target, select: select ?? nil)
    }

    /// Back (Cmd+[).
    public func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(folder)
        await show(previous, select: folder)
    }

    /// Forward (Cmd+]).
    public func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(folder)
        await show(next, select: nil)
    }

    /// Enclosing Folder (Cmd+Up), with the folder just left selected.
    public func goUp() async {
        guard canGoUp else { return }
        let child = folder
        await open(folder.deletingLastPathComponent(), select: child)
    }

    /// Go to Folder (Cmd+Shift+G). False when `text` names nothing.
    @discardableResult
    public func goTo(_ text: String) async -> Bool {
        guard let destination = resolver.resolve(text, relativeTo: folder) else {
            lastError = .missing(resolver.url(for: text, relativeTo: folder) ?? folder)
            return false
        }
        await open(destination.folder, select: destination.select)
        return true
    }

    /// Lists the current folder again.
    public func reload() async {
        await show(folder, select: nil, keepSelection: true)
    }

    /// Stops watching (the pane closed).
    public func stop() {
        watchTask?.cancel()
        watchTask = nil
    }

    private func show(_ target: URL, select: URL?, keepSelection: Bool = false) async {
        generation += 1
        let token = generation
        if target != folder {
            folder = target
            entries = []
            all = []
            selection = []
            cursor = nil
            filterText = ""
            if let prefs = memory?.prefs(for: target) {
                viewMode = prefs.viewMode
                sortOrder = prefs.sortOrder
            }
        }
        phase = .loading
        startWatching(target)
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let order = sortOrder
            let listed = try await Self.listSorted(target, lister: lister, order: order)
            guard token == generation else { return }
            all = listed
            lastLoadMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            phase = .ready
            refilter()
            if !keepSelection { selection = [] }
            if let select { self.select(select) }
        } catch let error as FileBrowserError {
            guard token == generation else { return }
            phase = .failed(Self.describe(error))
        } catch {
            guard token == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func rememberView() {
        memory?.remember(.init(viewMode: viewMode, sortOrder: sortOrder), for: folder)
    }

    @concurrent
    static func listSorted(_ folder: URL, lister: any DirectoryListing, order: FileSortOrder) async throws -> [FileEntry] {
        order.sorted(try await lister.list(folder))
    }

    func refilter() {
        let matcher = FileNameMatcher(filterText)
        let hidden = showHidden
        entries = all.filter { entry in (hidden || !entry.isHidden) && matcher.matches(entry.name) }
        indexCache = nil
        guard !selection.isEmpty || cursor != nil else { return }
        let present = Set(entries.lazy.map(\.name))
        if !selection.isSubset(of: present) { selection.formIntersection(present) }
        if let cursor, !present.contains(cursor) { self.cursor = nil }
    }

    // MARK: Selection

    /// Selects only the item named `name` and puts the cursor on it.
    public func select(_ name: String) {
        selection = [name]
        cursor = name
    }

    /// Selects only `url` (an item of the current folder) and puts the cursor on it.
    public func select(_ url: URL) { select(url.lastPathComponent) }

    /// Cmd-click: adds or removes `name`.
    public func toggle(_ name: String) {
        if selection.contains(name) { selection.remove(name) } else { selection.insert(name) }
        cursor = name
    }

    /// Shift-click: selects from the cursor to `name`.
    public func extend(to name: String) {
        guard let from = cursor.flatMap(index(of:)), let to = index(of: name) else { select(name); return }
        selection = Set(entries[min(from, to)...max(from, to)].map(\.name))
    }

    /// A layout's own selection change (click, arrows in a table): takes
    /// `names`, and `cursor` when given.
    public func adoptSelection(_ names: Set<String>, cursor: String?) {
        if selection != names { selection = names }
        if let cursor { self.cursor = cursor }
    }

    /// Select All (Cmd+A).
    public func selectAll() { selection = Set(entries.map(\.name)) }

    /// Moves the cursor by `delta` rows (arrows; a grid passes its column count
    /// for up and down). `extending` keeps the selection and adds the item (Shift).
    public func moveCursor(by delta: Int, extending: Bool = false) {
        guard !entries.isEmpty else { return }
        let current = cursor.flatMap(index(of:)) ?? (delta > 0 ? -1 : entries.count)
        let next = max(0, min(entries.count - 1, current + delta))
        let name = entries[next].name
        if extending {
            selection.insert(name)
            cursor = name
        } else {
            select(name)
        }
    }

    /// Moves the cursor to the first or last item (Home/End, Opt+Up/Down).
    public func moveCursorToEdge(last: Bool, extending: Bool = false) {
        moveCursor(by: last ? entries.count : -entries.count, extending: extending)
    }

    /// Type-select: typed characters pick the nearest name.
    public func typeSelect(_ characters: String) {
        let prefix = typeSelect.type(characters, at: now())
        let byName = sortOrder.field == .name && !sortOrder.foldersFirst ? entries : FileSortOrder().sorted(entries)
        guard let index = typeSelect.match(prefix, in: byName) else { return }
        select(byName[index].name)
    }

    /// The row of `name` in ``entries``.
    public func index(of name: String) -> Int? {
        if indexCache == nil {
            indexCache = Dictionary(entries.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return indexCache?[name]
    }

    // MARK: Opening

    /// What opening an item means to the pane.
    public enum Activation: Sendable, Equatable {
        /// The model now shows this folder.
        case openedFolder(URL)
        /// The host opens this file (default app, or a cmux viewer).
        case openFile(URL)
    }

    /// Opens `entry`: a folder (or a link to one) opens in place, anything
    /// else is for the host to open.
    public func activate(_ entry: FileEntry) async -> Activation {
        if entry.kind == .folder {
            await open(entry.url)
            return .openedFolder(entry.url)
        }
        if entry.kind == .symlink {
            let target = entry.url.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            // SAFETY: `isDir` is a local that outlives the call; Foundation writes one ObjCBool through the pointer
            // and keeps no reference to it after returning.
            if unsafe FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue,
               DirectoryLister.isPackage(target.lastPathComponent) == false {
                await open(target)
                return .openedFolder(target)
            }
        }
        return .openFile(entry.url)
    }

    static func wrap(_ error: any Error) -> FileBrowserError {
        (error as? FileBrowserError) ?? .failed(error.localizedDescription)
    }

    /// The pane's message for a listing failure (also read off main, by a watched relisting).
    nonisolated static func describe(_ error: FileBrowserError) -> String {
        switch error {
        case .unreadable(_, let code): FileBrowserError.systemText(code)
        case .failed(let message): message
        default: String(describing: error)
        }
    }
}
