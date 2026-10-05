public import AppKit

/// What a picker needs from its host: the file system, the recents store,
/// the explainer's memory, and how it asks before replacing a file. Every
/// part is injectable, so the models are tested on a temporary folder.
public struct PickerEnvironment {
    public var home: URL
    /// Recently chosen folders and files, newest first (absolute paths; a
    /// folder ends in `/`).
    public var recents: [String]
    /// The start folder's Locations after Recent (``PickerLocation/ordered(workspace:standard:pinned:)``).
    public var locations: [PickerLocation]
    /// Nil: no explainer (tests that do not cover it).
    public var explainer: (any PickerExplainerMemory)?
    public var overwrite: any PickerOverwriteConfirming
    /// Reads one folder level (off the main actor).
    public var list: @Sendable (URL, PickerMode, Int) async -> FolderListing
    public var fileExists: @MainActor (URL) -> Bool
    public var createFolder: @MainActor (URL) throws -> Void
    public var openSettings: @MainActor (URL) -> Void

    public init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        recents: [String] = [],
        locations: [PickerLocation] = [],
        explainer: (any PickerExplainerMemory)? = nil,
        overwrite: any PickerOverwriteConfirming = PalettePageOverwriteConfirmation(),
        list: @escaping @Sendable (URL, PickerMode, Int) async -> FolderListing = { await FolderListing.read($0, mode: $1, limit: $2) },
        fileExists: @escaping @MainActor (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        createFolder: @escaping @MainActor (URL) throws -> Void = {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false)
        },
        openSettings: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.home = home
        self.recents = recents
        self.locations = locations
        self.explainer = explainer
        self.overwrite = overwrite
        self.list = list
        self.fileExists = fileExists
        self.createFolder = createFolder
        self.openSettings = openSettings
    }
}

/// One run of the cmux picker (R89): the palette page that walks folders,
/// and the answer. Every step builds the page for the new place
/// (``PaletteHierarchy``); the session keeps what outlives a step (the
/// marked items of a multiple choice) and finishes exactly once: with the
/// chosen URLs, or nil when the user leaves the palette.
public final class PickerSession {
    public let environment: PickerEnvironment
    public let title: String?
    public let prompt: String?
    /// Marked items of a multiple choice, in the order marked.
    public private(set) var marked: [URL] = []
    private var onFinish: ((_ urls: [URL]?) -> Void)?

    public init(environment: PickerEnvironment, title: String? = nil, prompt: String? = nil,
                onFinish: @escaping (_ urls: [URL]?) -> Void) {
        self.environment = environment
        self.title = title
        self.prompt = prompt
        self.onFinish = onFinish
    }

    public var isFinished: Bool { onFinish == nil }

    /// Ends the run (the first call wins).
    public func finish(_ urls: [URL]?) {
        guard let onFinish else { return }
        self.onFinish = nil
        onFinish(urls)
    }

    func toggleMark(_ url: URL) {
        if let index = marked.firstIndex(of: url) { marked.remove(at: index) } else { marked.append(url) }
    }

    /// What Return chooses on `url`: the marked items and `url`.
    func choice(_ url: URL, mode: PickerMode) -> [URL] {
        guard mode.allowsMultiple else { return [url] }
        return marked.contains(url) ? marked : marked + [url]
    }

    // MARK: Pages

    /// The page of `state`: the explainer first when it enters a protected
    /// folder for the first time, else its listing. `query` is the save
    /// name carried across steps.
    public func page(for state: FolderPickerState, query: String = "", selecting: String? = nil,
                     back: FolderPickerState? = nil) -> PalettePageSpec {
        if let area = PickerPrivacy.area(of: state.directory.path, home: environment.home.path),
           let memory = environment.explainer, !memory.hasShownExplainer {
            return explainerPage(state, area: area, query: query, back: back)
        }
        return listingPage(state, query: query, selecting: selecting)
    }

    private func listingPage(_ state: FolderPickerState, query: String, selecting: String?) -> PalettePageSpec {
        let rows = PickerPageRows()
        let environment = environment
        // The pages hold the session (strongly): it lives while the palette
        // shows one of them, and the session holds no page back.
        let provider = AsyncPaletteProvider(id: "picker.listing") {
            let listing = await environment.list(state.directory, state.mode, state.limit)
            let made = FolderPickerRows.make(state: state, listing: listing, recents: environment.recents)
            rows.byID = Dictionary(made.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return self.locationItems(state, rows: rows) + self.items(for: made, state: state)
        }
        var page = PalettePageSpec(
            id: "picker", title: pageTitle(state),
            placeholder: placeholder(state.mode), symbol: state.mode.isSave ? "square.and.arrow.down" : "folder",
            providers: [provider], initialQuery: query, keepsSectionOrder: true, ranksPrefixFirst: true,
            onCancel: { self.finish(nil) },
            hierarchy: hierarchy(state, rows: rows),
            emptyQuerySelectionID: selecting ?? state.cameFrom.map { "dir:" + state.directory.appendingPathComponent($0).path },
            hint: state.mode.isSave ? PickerStrings.saveHint : PickerStrings.openHint,
            crumbs: crumbs(state)
        )
        if state.mode.isSave {
            page.filtersByQuery = false
            page.queryItems = { text in self.saveItems(text, state: state) }
            if !query.isEmpty { page.initialQuerySelection = PickerSaveName.selectionLength(query) }
        }
        return page
    }

    /// The footer: the caller's title, then the path.
    func pageTitle(_ state: FolderPickerState) -> String {
        let path = state.breadcrumb(home: environment.home)
        return title.map { $0 + "  \u{00B7}  " + path } ?? path
    }

    private func placeholder(_ mode: PickerMode) -> String {
        if let prompt { return prompt }
        switch mode.kind {
        case .save: return PickerStrings.namePlaceholder
        case .open(.folders): return PickerStrings.chooseFolder
        case .open(.files): return PickerStrings.chooseFile
        case .open(.filesOrFolders): return PickerStrings.chooseItem
        }
    }

    private func hierarchy(_ state: FolderPickerState, rows: PickerPageRows) -> PaletteHierarchy {
        PaletteHierarchy(
            enter: { item in
                if item.id == Self.recentLocationID { return self.recentPage(state) }
                guard let url = rows.locations[item.id] ?? rows.byID[item.id].flatMap({ $0.kind == .folder ? $0.url : nil }) else { return nil }
                return self.page(for: state.moving(to: url), back: state)
            },
            up: {
                guard let parent = state.up() else { return nil }
                return self.page(for: parent, back: state)
            },
            jump: { text in self.jump(text, from: state, rows: rows) }
        )
    }

    /// Typing filters, always; a query that starts with `/` or `~/` is a
    /// path (``pathPage(_:origin:)``). In a save picker any typed
    /// `folder/name` goes to the folder and keeps the name.
    private func jump(_ text: String, from state: FolderPickerState, rows: PickerPageRows) -> PalettePageSpec? {
        if state.mode.isSave {
            let (folder, name) = PickerSaveName.split(text)
            guard let folder else { return nil }
            let target = PickerSaveName.folder(folder, from: state.directory, home: environment.home)
            return page(for: state.moving(to: target), query: name, back: state)
        }
        return PickerPath.isPath(text) ? pathPage(text, origin: state) : nil
    }

    /// The footer's segments: each opens its folder.
    func crumbs(_ state: FolderPickerState) -> [PaletteCrumb] {
        state.crumbs(home: environment.home).map { crumb in
            PaletteCrumb(title: crumb.title) { self.page(for: state.moving(to: crumb.url), back: state) }
        }
    }

    private func explainerPage(_ state: FolderPickerState, area: PickerPrivacy.Area, query: String,
                               back: FolderPickerState?) -> PalettePageSpec {
        let section = PaletteSection(id: "explainer", title: "", order: 0)
        let info = PaletteItem(id: "explainer.info", title: PickerStrings.explainer(PickerStrings.area(area)),
                               subtitle: PickerStrings.explainerDetail, symbol: "hand.raised", section: section,
                               isEnabled: false, primary: PaletteCommand(id: "none", title: "", effect: .performKeepingOpen {}),
                               frecencyKey: nil)
        let next = PaletteItem(id: "explainer.continue", title: PickerStrings.continueTitle, symbol: "arrow.right.circle",
                               section: section,
                               primary: PaletteCommand(id: "continue", title: PickerStrings.continueTitle,
                                                       effect: .deferred {
                                                           .replace(self.page(for: state, query: query))
                                                       }),
                               frecencyKey: nil)
        var items = [info, next]
        if let back {
            items.append(PaletteItem(id: "explainer.back", title: PickerStrings.goBack, symbol: "arrow.uturn.backward",
                                     section: section,
                                     primary: PaletteCommand(id: "back", title: PickerStrings.goBack, effect: .deferred {
                                         .replace(self.page(for: back, query: query))
                                     }),
                                     frecencyKey: nil))
        }
        return PalettePageSpec(id: "picker.explainer", title: pageTitle(state),
                               placeholder: placeholder(state.mode), symbol: "hand.raised",
                               providers: [PickerExplainerProvider(items: items, memory: environment.explainer)],
                               keepsSectionOrder: true, onCancel: { self.finish(nil) },
                               emptyQuerySelectionID: "explainer.continue")
    }
}
