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
        d.send(.push("page.renameTab", row: "cmd.a"))
        #expect(d.chips == ["root", "page.renameTab"])
        #expect(d.top.entry == .command("cmd.a"))
        d.send(.escape)
        #expect(d.chips == ["root"])
        #expect(d.top.query == "ren")
    }

    @Test func unknownScopeOpensTheRootWithTheQuery() {
        var d = driver()
        let effects = d.send(.open(scope: "nope", query: "q"))
        #expect(d.chips == ["root"])
        #expect(d.top.query == "q")
        #expect(effects.contains(.refused(.unknownScope("nope"))))
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
