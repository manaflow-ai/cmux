import Foundation

/// Runs the scope reducer and its effects. Events raised while effects run
/// (a synchronous empty-query result, a command that pushes a page) queue
/// behind the current step, so each event sees the state its predecessor
/// left and the reducer is never re-entered.
extension PaletteModel {
    func send(_ event: PaletteNavEvent) {
        if case .open = event { startOver() }
        queue.append(event)
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            let effects = navigation.reduce(&nav, next)
            for effect in effects { perform(effect) }
        }
        mirror()
    }

    /// An open starts over: an open shortcut recorder, a hover and a held
    /// Cmd-W belong to the palette session that ends here.
    private func startOver() {
        actionsMenu = nil
        if shortcutRecorder != nil { onDropShortcutRecorder?() }
        shortcutRecorder = nil
        hoveredRowID = nil
        pendingClose = false
    }

    private func perform(_ effect: PaletteNavEffect) {
        switch effect {
        case .load(let levelID, let scope, let query, let generation, let context):
            load(levelID: levelID, scope: scope, query: query, generation: generation, context: context)
        case .cancel(let levelID):
            guard let state = pages.removeValue(forKey: levelID) else { return }
            state.cancel()
            leave(state)
        case .run(let levelID, let rowID):
            guard let state = pages[levelID], let item = state.item(id: rowID) else { return }
            let command = runCommand == .submitAlternate ? (item.alternate ?? item.primary) : item.primary
            runCommand = .submit
            run(command, of: item)
        case .openActions:
            _ = openActionsMenu()
        case .dismiss:
            onDismiss?()
        case .announceEntered(let scope), .announceLeft(let scope):
            onAnnounce?(chipTitle(scope: scope, page: nil))
        case .refused:
            break
        }
    }

    private func load(levelID: Int, scope: PaletteScopeID, query: String, generation: Int, context: String?) {
        // A level opened under another (the root under Search Tabs) gets
        // its page when it is first shown: popping to it loads it again.
        guard levelID == nav.top?.id else {
            pages[levelID]?.query = query
            pages[levelID]?.generation = generation
            return
        }
        let state: PageState
        if let existing = pages[levelID] {
            state = existing
        } else {
            state = makePage(scope: scope, context: context)
            state.levelID = levelID
            pages[levelID] = state
        }
        state.query = query
        state.generation = generation
        if state.needsLoad { load(state) }
        search(state)
    }

    /// The page for a new level: one the caller supplied, the graph
    /// scope's page, or an empty page.
    private func makePage(scope: PaletteScopeID, context: String?) -> PageState {
        if let supplied = suppliedPages.removeValue(forKey: scope) { return supplied }
        let contextItem = context.flatMap { id in nav.levels.dropLast().reversed().lazy.compactMap { self.pages[$0.id]?.item(id: id) }.first }
        if scope == .actionsScope, let item = contextItem {
            return PageState(kind: .list(PaletteItemActionsPage.make(for: item, model: self)))
        }
        if let page = scopePage?(scope, contextItem) { return PageState(kind: .list(page)) }
        return PageState(kind: .list(PalettePageSpec(id: scope.rawValue, title: "", placeholder: "", providers: [], scope: scope)))
    }

    /// Mirrors the top level into the observable properties.
    func mirror() {
        guard let top = nav.top, let state = pages[top.id] else {
            scopeChips = []
            keywordHint = nil
            return
        }
        if query != top.query {
            isMirroring = true
            query = top.query
            isMirroring = false
        }
        if shownLevelID != top.id {
            shownLevelID = top.id
            notice = nil
            actionsMenu = nil
            showChrome(of: state)
            if case .textInput(let spec) = state.kind {
                selectsQuery = !spec.initialText.isEmpty && top.query == spec.initialText
            } else {
                selectsQuery = false
            }
            // A level shown again (Backspace) shows its rows at once while
            // its refresh runs.
            if let cached = state.lastSections { display(cached) } else { display([]) }
            pageToken += 1
        }
        if selectedRowID != top.selection {
            selectedRowID = top.selection
            scrollRequest += 1
        }
        isLoading = !state.pendingProviders.isEmpty
        scopeChips = nav.levels.enumerated().dropFirst().map { index, level in
            PaletteScopeChip(levelIndex: index, scope: level.scope, title: chipTitle(scope: level.scope, page: pages[level.id]),
                             symbol: chipSymbol(scope: level.scope, page: pages[level.id]))
        }
        keywordHint = navigation.config.keywordEntry
            ? navigation.graph.child(of: top.scope, keyword: top.query).map {
                PaletteScopeChip(levelIndex: nav.depth, scope: $0.id, title: $0.title, symbol: $0.symbol)
            }
            : nil
    }

    private func showChrome(of state: PageState) {
        switch state.kind {
        case .list(let page):
            pageTitle = page.title
            placeholder = page.placeholder
            pageSymbol = page.symbol
            isTextInput = false
        case .textInput(let spec):
            pageTitle = spec.title
            placeholder = spec.placeholder
            pageSymbol = spec.symbol
            isTextInput = true
        }
    }

    func chipTitle(scope: PaletteScopeID, page: PageState?) -> String {
        navigation.graph.scopes[scope]?.title ?? page?.title ?? navigation.graph.root.title
    }

    private func chipSymbol(scope: PaletteScopeID, page: PageState?) -> String {
        navigation.graph.scopes[scope]?.symbol ?? page?.symbol ?? "command"
    }
}

nonisolated extension PaletteScopeID {
    /// The drill scope of any row: its commands.
    public static let actionsScope: PaletteScopeID = "actions"
}

extension PaletteScopeGraph {
    /// A graph with only the root: no prefixes or keywords (pages a caller
    /// opens and pushes).
    public static var rootOnly: PaletteScopeGraph {
        PaletteScopeGraph(
            root: PaletteScopeDescriptor(id: .root, title: PaletteStrings.commandsTitle, symbol: "command",
                                         placeholder: PaletteStrings.searchPlaceholder),
            scopes: [])
    }
}

extension PageState {
    /// The item of row `id` among the rows last shown on this page.
    func item(id: String) -> PaletteItem? {
        for section in lastSections ?? [] {
            if let row = section.rows.first(where: { $0.id == id }) { return row.item }
        }
        return nil
    }
}
