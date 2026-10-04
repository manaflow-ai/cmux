import AppKit
import CmuxNextActions
import CmuxNextPalette
import Testing

/// The palette's navigation state machine, driven by key commands.
@Suite struct PaletteNavigationTests {
    final class Log {
        var events: [String] = []
    }

    func item(_ id: String, _ title: String, log: Log, effect: PaletteEffect? = nil, secondary: [PaletteCommand] = []) -> PaletteItem {
        PaletteItem(
            id: id,
            title: title,
            primary: PaletteCommand(id: "run", title: "Run", effect: effect ?? .perform { log.events.append("run:\(id)") }),
            secondary: secondary
        )
    }

    func makeModel(_ items: [PaletteItem], log: Log) -> PaletteModel {
        let model = PaletteModel(persistence: InMemoryFrecencyPersistence())
        model.onDismiss = { log.events.append("dismiss") }
        model.reset(to: PalettePageSpec(
            id: "root",
            title: "Commands",
            placeholder: "Search",
            providers: [StaticPaletteProvider(id: "static", items: items)]
        ))
        return model
    }

    @Test func arrowsMoveAndWrap() {
        let log = Log()
        let model = makeModel([item("a", "Alpha", log: log), item("b", "Bravo", log: log), item("c", "Charlie", log: log)], log: log)
        #expect(model.selectedRowID == "a")
        model.handle(.moveDown)
        #expect(model.selectedRowID == "b")
        model.handle(.moveUp)
        model.handle(.moveUp)
        #expect(model.selectedRowID == "c")
        model.handle(.moveDown)
        #expect(model.selectedRowID == "a")
        model.handle(.moveToLast)
        #expect(model.selectedRowID == "c")
        model.handle(.pageUp)
        #expect(model.selectedRowID == "a")
    }

    @Test func typingResetsSelectionToBestMatch() async {
        let log = Log()
        let model = makeModel([item("a", "Alpha", log: log), item("b", "Bravo", log: log)], log: log)
        model.handle(.moveDown)
        model.query = "bra"
        await model.settle()
        #expect(model.rows.map(\.id) == ["b"])
        #expect(model.selectedRowID == "b")
        model.query = "zzz"
        await model.settle()
        #expect(model.rows.isEmpty)
        #expect(model.selectedRowID == nil)
        // Return with no row is consumed (never reaches the field editor or
        // the responder chain's beep) and runs nothing.
        #expect(model.handle(.submit))
        #expect(model.depth == 1)
    }

    @Test func submitRunsPrimaryAfterDismissing() {
        let log = Log()
        let model = makeModel([item("a", "Alpha", log: log)], log: log)
        model.handle(.submit)
        #expect(log.events == ["dismiss", "run:a"])
    }

    @Test func escapeClearsThenDismisses() async {
        let log = Log()
        let model = makeModel([item("a", "Alpha", log: log)], log: log)
        model.query = "al"
        await model.settle()
        model.handle(.escape)
        #expect(model.query == "")
        #expect(log.events.isEmpty)
        model.handle(.escape)
        #expect(log.events == ["dismiss"])
    }

    @Test func nestedListPushesAndPopsRestoringState() async {
        let log = Log()
        let child = PalettePageSpec(
            id: "child",
            title: "Go to Workspace",
            placeholder: "Search workspaces",
            providers: [StaticPaletteProvider(id: "ws", items: [item("w1", "api", log: log), item("w2", "web", log: log)])]
        )
        let model = makeModel([
            item("a", "Alpha", log: log),
            item("go", "Go to Workspace", log: log, effect: .push(child)),
        ], log: log)
        model.query = "go"
        await model.settle()
        model.handle(.submit)
        #expect(model.depth == 2)
        #expect(model.breadcrumbs == ["Go to Workspace"])
        #expect(model.query == "")
        #expect(model.rows.map(\.id) == ["w1", "w2"])
        model.handle(.moveDown)
        model.handle(.submit)
        #expect(log.events == ["dismiss", "run:w2"])

        // Backspace on an empty field pops and restores the parent query.
        #expect(model.handle(.back))
        await model.settle()
        #expect(model.depth == 1)
        #expect(model.query == "go")
        #expect(model.selectedRowID == "go")
        #expect(!model.handle(.back))
    }

    @Test func escapePopsBeforeClearing() async {
        let log = Log()
        let child = PalettePageSpec(id: "child", title: "Child", placeholder: "", providers: [])
        let model = makeModel([item("p", "Push", log: log, effect: .push(child))], log: log)
        model.handle(.submit)
        model.query = "x"
        await model.settle()
        model.handle(.escape)
        #expect(model.depth == 1)
        #expect(log.events.isEmpty)
    }

    @Test func textInputSubmitsTypedText() async {
        let log = Log()
        let spec = PaletteTextInputSpec(
            id: "rename",
            title: "Rename Tab",
            placeholder: "Tab name",
            initialText: "zsh",
            submitTitle: { "Rename to \($0)" },
            submit: { log.events.append("renamed:\($0)") }
        )
        let model = makeModel([item("r", "Rename Tab…", log: log, effect: .textInput(spec))], log: log)
        model.handle(.submit)
        #expect(model.isTextInput)
        #expect(model.query == "zsh")
        #expect(model.rows.first?.item.title == "Rename to zsh")

        model.query = "   "

        await model.settle()
        #expect(model.rows.first?.item.isEnabled == false)
        model.handle(.submit)
        #expect(log.events.isEmpty)

        model.query = "api"

        await model.settle()
        #expect(model.rows.first?.item.title == "Rename to api")
        model.handle(.submit)
        #expect(log.events == ["dismiss", "renamed:api"])
    }

    @Test func actionsMenuOpensFiltersAndRuns() throws {
        let log = Log()
        let model = makeModel([
            item("a", "Alpha", log: log, secondary: [
                PaletteCommand(id: "copy", title: "Copy ID", effect: .perform { log.events.append("copy") }),
                PaletteCommand(id: "close", title: "Close", isDestructive: true, effect: .perform { log.events.append("close") }),
            ]),
        ], log: log)
        model.handle(.toggleActions)
        let menu = try #require(model.actionsMenu)
        #expect(menu.commands.map(\.id) == ["run", "copy", "close"])

        model.handle(.moveDown)
        #expect(model.actionsMenu?.selectedIndex == 1)
        model.handle(.actionsFilterAppend("cl"))
        #expect(model.actionsMenu?.visibleCommands.map(\.id) == ["close"])
        #expect(model.actionsMenu?.selectedIndex == 0)
        model.handle(.actionsFilterDeleteBackward)
        #expect(model.actionsMenu?.filter == "c")

        // Esc closes the menu first, leaving the palette open.
        model.handle(.escape)
        #expect(model.actionsMenu == nil)
        #expect(log.events.isEmpty)

        model.handle(.openActions)
        model.handle(.moveDown)
        model.handle(.submit)
        #expect(model.actionsMenu == nil)
        #expect(log.events == ["dismiss", "copy"])
    }

    @Test func keepOpenCommandReloadsItems() async throws {
        let data = MockPaletteData()
        let model = PaletteModel(persistence: InMemoryFrecencyPersistence())
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.reset(to: PalettePageSpec(
            id: "settings",
            title: "Settings",
            placeholder: "",
            providers: [SettingsPaletteProvider(source: data, showsItemsForEmptyQuery: true)]
        ))
        model.query = "minimal"
        await model.settle()
        let before = try #require(model.selectedItem)
        #expect(before.accessory == "Off")
        model.handle(.submit)
        await model.settle()
        #expect(!dismissed)
        #expect(data.events == ["setToggle:sidebar.minimal:true"])
        #expect(model.selectedItem?.accessory == "On")
        #expect(model.selectedItem?.primary.title == "Turn Off")
    }

    @Test func asyncProviderMergesWithoutMovingSelection() async throws {
        let log = Log()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let slow = AsyncPaletteProvider(id: "slow") {
            for await _ in stream { break }
            return [PaletteItem(id: "late", title: "Alpha Late", primary: PaletteCommand(id: "run", title: "Run", effect: .perform {}))]
        }
        let model = PaletteModel(persistence: InMemoryFrecencyPersistence())
        model.reset(to: PalettePageSpec(id: "root", title: "Root", placeholder: "", providers: [
            StaticPaletteProvider(id: "fast", items: [item("a", "Alpha", log: log), item("b", "Alpha Bravo", log: log)]),
            slow,
        ]))
        model.handle(.moveDown)
        #expect(model.isLoading)
        #expect(model.rows.map(\.id) == ["a", "b"])

        continuation.yield()
        continuation.finish()
        for _ in 0..<1000 where model.isLoading { await Task.yield() }
        #expect(!model.isLoading)
        #expect(model.rows.map(\.id) == ["a", "b", "late"])
        #expect(model.selectedRowID == "b")
    }

    @Test func registryPaletteServesRenameWithInlineEntry() async throws {
        let registry = ActionRegistry.standard()
        let data = MockPaletteData()
        let controller = PaletteController(registry: registry, sources: data.sources, frecencyPersistence: nil)
        let model = controller.model
        model.reset(to: controller.commandsPage())
        model.query = "rename tab"
        await model.settle()
        #expect(model.selectedRowID == "action:renameTab")
        model.handle(.submit)
        #expect(model.isTextInput)
        #expect(model.query == "zsh")
        model.query = "build"
        await model.settle()
        model.handle(.submit)
        #expect(data.events == ["renameTab:t1:build"])
    }

    @Test func goToWorkspaceOpensNestedList() async {
        let registry = ActionRegistry.standard()
        let data = MockPaletteData()
        let controller = PaletteController(registry: registry, sources: data.sources, frecencyPersistence: nil)
        let model = controller.model
        model.reset(to: controller.commandsPage())
        model.query = "go to workspace"
        await model.settle()
        model.handle(.submit)
        #expect(model.depth == 2)
        #expect(model.rows.count == data.workspaces.count)
        model.query = "ghostty"
        await model.settle()
        model.handle(.submit)
        #expect(data.events == ["selectWorkspace:w4"])
    }

    @Test func rootHidesDynamicItemsUntilTyping() async {
        let registry = ActionRegistry.standard()
        let data = MockPaletteData()
        let controller = PaletteController(registry: registry, sources: data.sources, frecencyPersistence: nil)
        let model = controller.model
        model.reset(to: controller.commandsPage())
        #expect(!model.rows.contains { $0.id.hasPrefix("workspace:") })
        model.query = "ghostty fork"
        await model.settle()
        #expect(model.rows.first?.id == "workspace:w4")
    }

    @Test func keyMapTranslatesEvents() throws {
        let registry = ActionRegistry.standard()
        func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code
            ))
        }
        func command(_ event: NSEvent, menu: Bool = false, empty: Bool = false) -> PaletteKeyCommand? {
            PaletteKeyMap.command(for: event, actionsMenuOpen: menu, queryIsEmpty: empty, registry: registry)
        }
        #expect(command(try key(125, Shortcut.downArrowKey)) == .moveDown)
        #expect(command(try key(126, Shortcut.upArrowKey, .command)) == .moveToFirst)
        #expect(command(try key(45, "n", .control)) == .moveDown)
        #expect(command(try key(35, "p", .control)) == .moveUp)
        // R85: the list bindings (list.next / list.previous, Ctrl-J / Ctrl-K) move the palette too.
        #expect(command(try key(38, "j", .control)) == .moveDown)
        #expect(command(try key(40, "k", .control)) == .moveUp)
        #expect(command(try key(36, "\r")) == .submit)
        #expect(command(try key(36, "\r", .command)) == .submitAlternate)
        #expect(command(try key(40, "k", .command)) == .toggleActions)
        #expect(command(try key(48, "\t")) == .openActions)
        #expect(command(try key(53, "\u{1B}")) == .escape)
        #expect(command(try key(51, "\u{7F}"), empty: true) == .back)
        #expect(command(try key(51, "\u{7F}"), empty: false) == nil)
        #expect(command(try key(0, "a")) == nil)
        #expect(command(try key(0, "a"), menu: true) == .actionsFilterAppend("a"))

        // Palette Next follows the user's override.
        registry.setShortcutOverride(Shortcut("j", modifiers: [.control]), for: "commandPaletteNext")
        #expect(command(try key(38, "j", .control)) == .moveDown)
    }
}
