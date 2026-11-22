import CmuxNextPalette
import Testing

/// The scope state machine, rule by rule (plans/cmux-next/palette-scopes.md
/// section 4.3).
@Suite struct PaletteNavReducerTests {
    typealias F = PaletteNavFixtures

    func driver() -> PaletteNavDriver {
        var driver = PaletteNavDriver()
        driver.rowsByScope = [
            .root: F.rows(["cmd.a", "cmd.b", "cmd.c"]),
            F.tabs: F.rows(["tab.current", "tab.previous", "tab.other"]),
            F.workspaces: F.rows(["ws.1", "ws.2"]),
            F.actions: F.rows(["act.close", "act.rename"], drills: nil),
            F.closed: F.rows(["closed.1"]),
            F.scopes: [PaletteNavRow(id: "scope.tabs", enters: F.tabs), PaletteNavRow(id: "scope.ws", enters: F.workspaces)],
        ]
        return driver
    }

    @Test func searchTabsThenBackspaceShowsTheFullPalette() {
        var d = driver()
        d.send(.open(scope: F.tabs, query: ""))
        #expect(d.chips == ["root", "tabs"])
        // Search Tabs selects the previous tab on an empty query.
        #expect(d.top.selection == "tab.previous")
        d.send(.backspaceOnEmpty)
        #expect(d.chips == ["root"])
        #expect(d.state.isOpen)
        // Backspace at the root is consumed and keeps the palette open.
        #expect(d.send(.backspaceOnEmpty).isEmpty)
        #expect(d.state.isOpen)
    }

    @Test func prefixEntersFromAnEmptyQueryOnly() {
        var d = driver()
        d.send(.open(scope: nil, query: ""))
        d.send(.setQuery("@"))
        #expect(d.chips == ["root", "tabs"])
        #expect(d.top.query == "")
        #expect(d.top.entry == .prefix("@"))
        d.send(.backspaceOnEmpty)
        #expect(d.top.query == "")
        // Pasted text with a prefix enters with the rest as the query.
        d.send(.setQuery("#prod"))
        #expect(d.chips == ["root", "workspaces"])
        #expect(d.top.query == "prod")
        d.send(.setQuery(""))
        d.send(.backspaceOnEmpty)
        // A prefix after other text is literal.
        d.send(.setQuery("a"))
        d.send(.setQuery("a@"))
        #expect(d.chips == ["root"])
        #expect(d.top.query == "a@")
    }

    @Test func prefixEntryCanBeTurnedOff() {
        var d = driver()
        d.reducer.config.prefixEntry = false
        d.send(.open(scope: nil, query: ""))
        d.send(.setQuery("@"))
        #expect(d.chips == ["root"])
        #expect(d.top.query == "@")
    }

    @Test func keywordPlusTabEntersAndConsumesTheKeyword() {
        var d = driver()
        d.send(.open(scope: nil, query: ""))
        d.send(.setQuery("Tabs "))
        d.send(.tab)
        #expect(d.chips == ["root", "tabs"])
        #expect(d.top.entry == .keyword("tabs"))
        d.send(.backspaceOnEmpty)
        #expect(d.chips == ["root"])
        #expect(d.top.query == "")
    }

    @Test func tabDrillsAndBackspaceRestoresQueryAndSelection() {
        var d = driver()
        d.send(.open(scope: F.tabs, query: "o"))
        d.send(.move(2))
        #expect(d.top.selection == "tab.other")
        d.send(.tab)
        #expect(d.chips == ["root", "tabs", "actions"])
        #expect(d.top.context == "tab.other")
        d.send(.backspaceOnEmpty)
        #expect(d.chips == ["root", "tabs"])
        #expect(d.top.query == "o")
        #expect(d.top.selection == "tab.other")
    }

    @Test func nestedScopesOnlyFromTheirParent() {
        var d = driver()
        d.send(.open(scope: nil, query: ""))
        // `!` belongs to Tabs, so it is literal at the root.
        d.send(.setQuery("!"))
        #expect(d.chips == ["root"])
        d.send(.setQuery(""))
        d.send(.setQuery("@"))
        d.send(.setQuery("!"))
        #expect(d.chips == ["root", "tabs", "closed"])
        d.send(.popTo(0))
        #expect(d.chips == ["root"])
    }

    @Test func scopeRowsEnterOnReturnAndTab() {
        var d = driver()
        d.send(.open(scope: nil, query: ""))
        d.send(.setQuery("?"))
        #expect(d.chips == ["root", "scopes"])
        d.send(.activate(nil))
        #expect(d.chips == ["root", "scopes", "tabs"])
        #expect(d.top.entry == .row("scope.tabs"))
        d.send(.backspaceOnEmpty)
        d.send(.move(1))
        d.send(.tab)
        #expect(d.chips == ["root", "scopes", "workspaces"])
    }

    @Test func tabWithNothingToEnterOpensActions() {
        var d = driver()
        d.rowsByScope[.root] = F.rows(["cmd.a"], drills: nil)
        d.send(.open(scope: nil, query: ""))
        #expect(d.send(.tab) == [.openActions(rowID: "cmd.a")])
    }

    @Test func escapePopsPushedLevelsThenClearsThenCloses() {
        var d = driver()
        d.send(.open(scope: F.tabs, query: "x"))
        d.send(.tab)  // drill
        #expect(d.chips == ["root", "tabs", "actions"])
        d.send(.escape)
        #expect(d.chips == ["root", "tabs"])
        // The opened level clears, then closes (Esc never shows the root).
        d.send(.escape)
        #expect(d.top.query == "")
        #expect(d.chips == ["root", "tabs"])
        #expect(d.send(.escape).contains(.dismiss))
        #expect(!d.state.isOpen)
        #expect(d.state.levels.isEmpty)
    }

    @Test func staleBatchesAreDropped() {
        var d = driver()
        d.send(.open(scope: nil, query: ""), answer: false)
        let level = d.top.id
        d.send(.setQuery("a"), answer: false)
        let before = d.state
        let effects = d.send(.results(levelID: level, generation: 1, rows: F.rows(["old"]), replace: true, isFinal: true))
        #expect(effects.isEmpty)
        #expect(d.state == before)
    }

    @Test func returnWaitsForTheCurrentQuery() {
        var d = driver()
        d.send(.open(scope: nil, query: ""))
        d.send(.setQuery("b"), answer: false)
        #expect(d.send(.activate(nil)).isEmpty)
        let level = d.top
        let effects = d.send(.results(levelID: level.id, generation: level.generation, rows: F.rows(["cmd.b"]), replace: true, isFinal: true))
        #expect(effects == [.run(levelID: level.id, rowID: "cmd.b")])
    }

    /// state-audit P1: a Return that waits for its query's rows belongs to that query. Escape (which
    /// clears the query) and new typing drop it, so the next results run nothing.
    @Test func aWaitingReturnDiesWithItsQuery() {
        var d = driver()
        d.send(.open(scope: nil, query: ""))
        d.send(.setQuery("b"), answer: false)
        #expect(d.send(.activate(nil)).isEmpty)
        d.send(.escape, answer: false)
        d.send(.setQuery("c"), answer: false)
        let level = d.top
        let effects = d.send(.results(levelID: level.id, generation: level.generation, rows: F.rows(["cmd.c"]), replace: true, isFinal: true))
        #expect(effects.isEmpty, "no command runs that the user did not confirm")
    }

    /// The live bug (query "settings"): the user typed, arrowed to a row of the rows on screen
    /// (an older query's), and pressed Return. Return must run that highlighted row once the
    /// current query's rows land, never the new top row.
    @Test func returnRunsTheRowTheUserMovedToWhileRowsWereStale() {
        var d = driver()
        d.send(.open(scope: nil, query: ""), answer: false)
        let level = d.top
        d.send(.results(levelID: level.id, generation: level.generation, rows: F.rows(["scope.settings", "toggle", "openSettings"]),
                        replace: true, isFinal: true))
        d.send(.setQuery("settings"), answer: false)
        d.send(.move(1))
        d.send(.move(1))
        #expect(d.top.selection == "openSettings", "the highlight is on the row the user chose")
        #expect(d.send(.activate(nil)).isEmpty, "Return waits for the current query's rows")
        let effects = d.send(.results(levelID: level.id, generation: d.top.generation,
                                      rows: F.rows(["scope.settings", "toggle", "openSettings"]), replace: true, isFinal: true))
        #expect(effects == [.run(levelID: level.id, rowID: "openSettings")])
        #expect(d.top.selection == "openSettings")
    }

    /// When the chosen row is not in the current query's rows, Return runs nothing: the highlight
    /// moves where the user can see it, and the next Return runs what it shows.
    @Test func returnRunsNothingWhenTheChosenRowLeavesTheResults() {
        var d = driver()
        d.send(.open(scope: nil, query: ""), answer: false)
        let level = d.top
        d.send(.results(levelID: level.id, generation: level.generation, rows: F.rows(["a", "b", "c"]), replace: true, isFinal: true))
        d.send(.setQuery("x"), answer: false)
        d.send(.move(1))
        #expect(d.send(.activate(nil)).isEmpty)
        // A first batch without the chosen row: keep waiting while more rows come.
        #expect(d.send(.results(levelID: level.id, generation: d.top.generation, rows: F.rows(["x1"]), replace: true, isFinal: false)).isEmpty)
        #expect(d.send(.results(levelID: level.id, generation: d.top.generation, rows: F.rows(["x2"]), replace: false, isFinal: true)).isEmpty)
        #expect(d.top.selection != nil && d.top.selection != "b")
        #expect(d.send(.activate(nil)) == [.run(levelID: level.id, rowID: d.top.selection!)])
    }

    /// A row the user chose stays chosen when its row arrives in a later batch of the same query.
    @Test func aChosenRowInALaterBatchRuns() {
        var d = driver()
        d.send(.open(scope: nil, query: ""), answer: false)
        let level = d.top
        d.send(.results(levelID: level.id, generation: level.generation, rows: F.rows(["a", "b"]), replace: true, isFinal: true))
        d.send(.setQuery("q"), answer: false)
        d.send(.move(1))
        d.send(.activate(nil))
        #expect(d.send(.results(levelID: level.id, generation: d.top.generation, rows: F.rows(["a"]), replace: true, isFinal: false)).isEmpty)
        let effects = d.send(.results(levelID: level.id, generation: d.top.generation, rows: F.rows(["b"]), replace: false, isFinal: true))
        #expect(effects == [.run(levelID: level.id, rowID: "b")])
    }

    /// The live case (query "settings", rows shown for it, Settings… highlighted): a refresh of the
    /// same query (the App's data changed) made the rows "stale", Return waited, and the refreshed
    /// rows ran another row at the old index. Rows of the current query text are what the user
    /// sees: Return runs the highlighted one at once.
    @Test func returnDuringARefreshOfTheSameQueryRunsTheHighlightedRow() {
        var d = driver()
        d.send(.open(scope: nil, query: ""), answer: false)
        let level = d.top
        d.send(.setQuery("settings"), answer: false)
        d.send(.results(levelID: level.id, generation: d.top.generation, rows: F.rows(["openSettings", "toggle"]),
                        replace: true, isFinal: true))
        #expect(d.top.selection == "openSettings")
        d.send(.refresh, answer: false)
        #expect(!d.top.rowsAreCurrent)
        #expect(d.send(.activate(nil)) == [.run(levelID: level.id, rowID: "openSettings")])
    }

    @Test func streamingAppendsKeepTheSelection() {
        var d = driver()
        d.send(.open(scope: nil, query: ""), answer: false)
        let level = d.top
        d.send(.results(levelID: level.id, generation: level.generation, rows: F.rows(["a", "b"]), replace: true, isFinal: false))
        #expect(d.top.isLoading)
        d.send(.move(1))
        d.send(.results(levelID: level.id, generation: level.generation, rows: F.rows(["b", "c"]), replace: false, isFinal: true))
        #expect(d.top.rows.map(\.id) == ["a", "b", "c"])
        #expect(d.top.selection == "b")
        #expect(!d.top.isLoading)
    }

    @Test func refreshKeepsTheSelectionByIDThenByIndex() {
        var d = driver()
        d.send(.open(scope: nil, query: ""))
        d.send(.move(2))
        #expect(d.top.selection == "cmd.c")
        d.rowsByScope[.root] = F.rows(["cmd.c", "cmd.a"])
        d.send(.refresh)
        #expect(d.top.selection == "cmd.c")
        d.rowsByScope[.root] = F.rows(["cmd.x", "cmd.y", "cmd.z"])
        d.send(.refresh)
        // Gone: the row at the same index (0).
        #expect(d.top.selection == "cmd.x")
    }

    @Test func depthIsBounded() {
        var d = driver()
        d.reducer.config.maxDepth = 3
        d.send(.open(scope: F.tabs, query: ""))
        d.send(.tab)  // actions: depth 3
        #expect(d.state.depth == 3)
        d.rowsByScope[F.actions] = F.rows(["deeper"])
        d.send(.refresh)
        #expect(d.send(.tab) == [.refused(.depthLimit)])
        #expect(d.state.depth == 3)
    }

    @Test func commandPagesPushOutsideTheGraphAndPopLikeScopes() {
        var d = driver()
        d.send(.open(scope: nil, query: "ren"))
        d.send(.push("page.renameTab", row: "cmd.a", query: "old name"))
        #expect(d.chips == ["root", "page.renameTab"])
        #expect(d.top.entry == .command("cmd.a"))
        #expect(d.top.query == "old name")
        d.send(.escape)
        #expect(d.chips == ["root"])
        #expect(d.top.query == "ren")
    }

    @Test func anyPageOpensAboveTheRoot() {
        var d = driver()
        d.send(.open(scope: "page.pickWorkspace", query: "q"))
        #expect(d.chips == ["root", "page.pickWorkspace"])
        #expect(d.top.query == "q")
        #expect(d.top.entry == .opened)
        // Esc on an opened page closes; it never shows the root.
        d.send(.escape)
        #expect(d.send(.escape).contains(.dismiss))
    }

    @Test func aBatchCanChooseTheEmptyQueryRow() {
        var d = driver()
        d.send(.open(scope: F.workspaces, query: ""), answer: false)
        let level = d.top
        d.send(.results(levelID: level.id, generation: level.generation, rows: F.rows(["a", "b", "c"]), replace: true,
                        isFinal: true, emptyQuerySelection: 2))
        #expect(d.top.selection == "c")
    }

    @Test func graphRefusesBadPrefixesAndCollisions() {
        let graph = PaletteScopeGraph(root: F.scope(.root), scopes: [
            F.scope("a", prefix: "@", keywords: ["alpha"]),
            F.scope("b", prefix: "@", keywords: ["alpha", "beta"]),
            F.scope("c", prefix: "x"),
            F.scope("d", prefix: "@", parents: .only(["a"])),
            F.scope(.root),
            F.scope("a"),
        ])
        #expect(graph.descriptor("b")?.prefix == nil)
        #expect(graph.descriptor("b")?.keywords == ["beta"])
        #expect(graph.descriptor("c")?.prefix == nil)
        // A prefix may repeat under a different parent.
        #expect(graph.descriptor("d")?.prefix == "@")
        #expect(graph.child(of: "a", prefix: "@")?.id == "d")
        #expect(graph.child(of: .root, prefix: "@")?.id == "a")
        #expect(graph.problems.contains(.prefixCollision("b", with: "a", prefix: "@")))
        #expect(graph.problems.contains(.keywordCollision("b", with: "a", keyword: "alpha")))
        #expect(graph.problems.contains(.invalidPrefix("c", "x")))
        #expect(graph.problems.contains(.reservedID(.root)))
        #expect(graph.problems.contains(.duplicateID("a")))
    }
}
