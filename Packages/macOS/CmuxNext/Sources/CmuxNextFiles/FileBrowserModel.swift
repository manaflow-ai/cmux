public import Foundation
import Observation

/// One Files pane's state: the folder shown, its sorted and filtered items,
/// the selection, history, view options and undo.
///
/// Listing and sorting run off the main actor (``DirectoryListing``); live
/// changes arrive through ``FolderWatching`` and update single rows. Every
/// dependency comes through `init`, so tests drive the model against a temp
/// folder or fakes:
///
/// ```swift
/// let model = FileBrowserModel(folder: tempFolder)
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
    public private(set) var phase: Phase = .loading
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

    /// Whether the pane shows (its view is in a window and not hidden; ``setShown(_:)``). While it does not, watched
    /// changes are only noted, and showing it catches up once.
    @ObservationIgnored public private(set) var isShown = true
    /// Sorts of the whole folder run (tests and the perf panel).
    @ObservationIgnored public internal(set) var fullSorts = 0
    /// Every item of the folder, sorted by ``allOrder``; ``entries`` is it filtered.
    @ObservationIgnored var all: [FileEntry] = [] { didSet { if !isSplicing { byName = nil } } }
    /// The order ``all`` is sorted in (``sortOrder`` once a re-sort lands).
    @ObservationIgnored var allOrder = FileSortOrder()
    /// ``all`` by name, made when a watched change first needs it and dropped when ``all`` is listed again.
    @ObservationIgnored private var byName: [String: FileEntry]?
    @ObservationIgnored private var isSplicing = false
    /// Watched changes while the pane was hidden: the names, or the whole folder (a rescan, or too many names).
    @ObservationIgnored private var owed: (names: Set<String>, rescan: Bool) = ([], false)
    /// More changed names than this in one batch (or owed while hidden) list the folder again.
    static let namedChangesLimit = 500
    @ObservationIgnored private var backStack: [URL] = []
    @ObservationIgnored private var forwardStack: [URL] = []
    @ObservationIgnored var undoStack: [FileUndoAction] = []
    @ObservationIgnored var redoStack: [FileUndoAction] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var typeSelect = TypeSelectBuffer()
    @ObservationIgnored private var indexCache: [String: Int]?
    @ObservationIgnored let lister: any DirectoryListing
    @ObservationIgnored private let watcher: any FolderWatching
    @ObservationIgnored let files: any FileOperating
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let resolver: GoToFolderResolver
    @ObservationIgnored private let memory: FolderViewMemory?

    /// Makes a model on `folder`; call ``reload()`` (or ``open(_:)``) to list it.
    /// - Parameters:
    ///   - folder: The first folder.
    ///   - viewMode: The first layout. Defaults to list.
    ///   - sortOrder: The first order. Defaults to Finder's (name, ascending).
    ///   - showHidden: Show hidden items. Defaults to false.
    ///   - lister: Reads folders. Defaults to ``DirectoryLister``.
    ///   - watcher: Reports changes. Defaults to ``FolderWatcher``.
    ///   - files: Makes changes. Defaults to ``FileOperator``.
    ///   - resolver: Resolves Go to Folder text. Defaults to the real file system.
    ///   - now: The clock type-select reads (a seam for tests).
    ///   - memory: Each folder's remembered view and order; nil keeps one for all.
    public init(folder: URL, viewMode: FileViewMode = .list, sortOrder: FileSortOrder = FileSortOrder(),
                showHidden: Bool = false, lister: any DirectoryListing = DirectoryLister(),
                watcher: any FolderWatching = FolderWatcher(), files: any FileOperating = FileOperator(),
                resolver: GoToFolderResolver = GoToFolderResolver(), now: @escaping @Sendable () -> Date = { Date() },
                memory: FolderViewMemory? = nil) {
        self.folder = folder.standardizedFileURL
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

    /// The pane was shown or hidden (its view moved into or out of a window, or was hidden). Showing it applies what
    /// changed meanwhile, once: the noted items, or the folder listed again after a rescan. Returns that catch-up's
    /// task (nil: nothing was owed).
    @discardableResult
    public func setShown(_ shown: Bool) -> Task<Void, Never>? {
        guard shown != isShown else { return nil }
        isShown = shown
        guard shown, owed.rescan || !owed.names.isEmpty else { return nil }
        let target = folder
        // task-owner: one catch-up; ends when the owed changes are applied
        return Task { [weak self] in await self?.catchUp(in: target) }
    }

    private func catchUp(in target: URL) async {
        guard isShown, target == folder else { return }
        let (names, rescan) = owed
        owed = ([], false)
        if rescan {
            await show(folder, select: nil, keepSelection: true)
        } else if !names.isEmpty {
            await apply(.items(Array(names)), in: target)
        }
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
        owed = ([], false) // this listing has every change noted so far
        startWatching(target, token: token)
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let order = sortOrder
            fullSorts += 1
            let listed = try await Self.listSorted(target, lister: lister, order: order)
            guard token == generation else { return }
            all = listed
            allOrder = order
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

    @concurrent
    private static func sortOff(_ entries: [FileEntry], order: FileSortOrder) async -> [FileEntry] {
        order.sorted(entries)
    }

    private func startWatching(_ target: URL, token: Int) {
        watchTask?.cancel()
        let stream = watcher.changes(in: target)
        watchTask = Task { [weak self] in
            for await change in stream {
                guard let self, token == self.generation || self.folder == target else { return }
                await self.apply(change, in: target)
            }
        }
    }

    /// Applies one watched change (single rows, or a full listing on rescan). While the pane is hidden it is only
    /// noted (``setShown(_:)`` applies it); a shown pane reads each changed item and splices it into place
    /// (``splice(_:)``). It read and re-sorted the whole folder per FSEvents batch, shown or not (audit 2026-11-18
    /// section 16; Leo: "Why should non visible thing even affect the renderer thread anyways?").
    func apply(_ change: FolderChange, in target: URL) async {
        guard target == folder else { return }
        guard isShown else {
            switch change {
            case .rescan: owed = ([], true)
            case .items(let names):
                guard !owed.rescan else { return }
                owed.names.formUnion(names)
                if owed.names.count > Self.namedChangesLimit { owed = ([], true) }
            }
            return
        }
        switch change {
        case .rescan:
            await show(folder, select: nil, keepSelection: true)
        case .items(let names):
            if names.count > Self.namedChangesLimit { await show(folder, select: nil, keepSelection: true); return }
            var read: [(name: String, entry: FileEntry?)] = []
            for name in Set(names) {
                let url = folder.appendingPathComponent(name)
                let entry = await lister.entry(at: url).map {
                    FileEntry(name: name, in: folder, kind: $0.kind, size: $0.size, modified: $0.modified, created: $0.created,
                              isHidden: $0.isHidden)
                }
                read.append((name, entry))
            }
            guard target == folder else { return }
            splice(read)
        }
    }

    /// Puts each changed item (nil: gone) at its place in ``all`` and ``entries``, which stay sorted: a binary search
    /// per item and an insert or removal, never a sort or a filter of the folder.
    private func splice(_ changes: [(name: String, entry: FileEntry?)]) {
        if byName == nil { byName = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }) }
        let order = allOrder
        let matcher = FileNameMatcher(filterText)
        let hidden = showHidden
        func listed(_ entry: FileEntry) -> Bool { (hidden || !entry.isHidden) && matcher.matches(entry.name) }
        // `shown` is the only reference to the rows while they change: no copy of the folder.
        var shown = entries
        entries = []
        isSplicing = true
        var unlisted: [String] = []
        for (name, entry) in changes {
            if let old = byName?[name] {
                if let index = Self.index(of: old, in: all, order: order) { all.remove(at: index) }
                if listed(old), let index = Self.index(of: old, in: shown, order: order) { shown.remove(at: index) }
            }
            byName?[name] = entry
            guard let entry else {
                unlisted.append(name)
                continue
            }
            all.insert(entry, at: Self.insertionIndex(of: entry, in: all, order: order))
            if listed(entry) {
                shown.insert(entry, at: Self.insertionIndex(of: entry, in: shown, order: order))
            } else {
                unlisted.append(name)
            }
        }
        isSplicing = false
        entries = shown
        indexCache = nil
        for name in unlisted {
            if selection.contains(name) { selection.remove(name) }
            if cursor == name { cursor = nil }
        }
    }

    /// Where `entry` goes in `list` (sorted by `order`): the first row it does not come after.
    private static func insertionIndex(of entry: FileEntry, in list: [FileEntry], order: FileSortOrder) -> Int {
        var low = 0
        var high = list.count
        while low < high {
            let middle = (low + high) / 2
            if order.inOrder(list[middle], entry) { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The row of `entry` in `list` (sorted by `order`; names are unique, so the order is total).
    private static func index(of entry: FileEntry, in list: [FileEntry], order: FileSortOrder) -> Int? {
        let index = insertionIndex(of: entry, in: list, order: order)
        return index < list.count && list[index].name == entry.name ? index : nil
    }

    private func resort() {
        let order = sortOrder
        let snapshot = all
        let token = generation
        Task { [weak self] in
            let sorted = await Self.sortOff(snapshot, order: order)
            guard let self, token == self.generation else { return }
            self.fullSorts += 1
            self.all = sorted
            self.allOrder = order
            self.refilter()
        }
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
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue,
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

    private static func describe(_ error: FileBrowserError) -> String {
        switch error {
        case .unreadable(_, let code): String(cString: strerror(code))
        case .failed(let message): message
        default: String(describing: error)
        }
    }
}
