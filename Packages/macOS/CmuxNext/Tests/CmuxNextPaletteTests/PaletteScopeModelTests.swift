import CmuxNextPalette
import Testing

/// The palette model on the scope reducer: chips, Backspace to the root,
/// prefix and keyword entry, drill into a row's actions, and a root that
/// is built only when shown.
@Suite struct PaletteScopeModelTests {
    final class Log {
        var events: [String] = []
        var rootBuilds = 0
    }

    static let tabs: PaletteScopeID = "tabs"

    func item(_ id: String, _ title: String, log: Log, secondary: [String] = []) -> PaletteItem {
        PaletteItem(
            id: id, title: title,
            primary: PaletteCommand(id: "run", title: "Run", effect: .perform { log.events.append("run:\(id)") }),
            secondary: secondary.map { name in
                PaletteCommand(id: name, title: name.capitalized, effect: .perform { log.events.append("\(name):\(id)") })
            })
    }

    func makeModel(log: Log, itemActionsAsScope: Bool = false) -> PaletteModel {
        let model = PaletteModel(persistence: InMemoryFrecencyPersistence())
        model.onDismiss = { log.events.append("dismiss") }
        model.navigation = PaletteNavReducer(graph: PaletteScopeGraph(
            root: PaletteScopeDescriptor.paletteRoot,
            scopes: [
                PaletteScopeDescriptor(id: Self.tabs, title: "Tabs", symbol: "rectangle.on.rectangle", placeholder: "Search tabs…",
                                       prefix: "@", keywords: ["tabs"], emptyQuerySelection: 1),
                PaletteScopeDescriptor(id: .actionsScope, title: "Actions", symbol: "filemenu.and.selection", placeholder: "Search actions…",
                                       parents: .only([])),
            ]))
        model.itemActionsAsScope = itemActionsAsScope
        let root = [item("cmd.a", "Alpha", log: log), item("cmd.b", "Bravo", log: log)]
        let tabs = [item("tab.current", "Current", log: log, secondary: ["close"]), item("tab.previous", "Previous", log: log, secondary: ["close"])]
        model.scopePage = { scope, _ in
            switch scope {
            case .root:
                log.rootBuilds += 1
                return PalettePageSpec(id: "commands", title: "Commands", placeholder: "Search for commands…",
                                       providers: [StaticPaletteProvider(id: "root", items: root)], scope: .root)
            case Self.tabs:
                return PalettePageSpec(id: "tabSearch", title: "Search Tabs", placeholder: "Search tabs…",
                                       providers: [StaticPaletteProvider(id: "tabs", items: tabs)], emptyQuerySelection: 1, scope: Self.tabs)
            default:
                return nil
            }
        }
        return model
    }

    @Test func openedScopeBackspacesToTheFullPalette() {
        let log = Log()
        let model = makeModel(log: log)
        model.open(scope: Self.tabs)
        #expect(model.scopeChips.map(\.title) == ["Tabs"])
        #expect(model.placeholder == "Search tabs…")
        #expect(model.selectedRowID == "tab.previous")
        // The root is built only when it is shown.
        #expect(log.rootBuilds == 0)
        model.handle(.back)
        #expect(model.scopeChips.isEmpty)
        #expect(model.pageTitle == "Commands")
        #expect(model.rows.map(\.id) == ["cmd.a", "cmd.b"])
        #expect(log.rootBuilds == 1)
        // Esc on the opened scope closes; it never shows the root.
        model.open(scope: Self.tabs)
        model.handle(.escape)
        #expect(log.events == ["dismiss"])
    }

    @Test func prefixEntersAndBackspaceRestoresTheRoot() {
        let log = Log()
        let model = makeModel(log: log)
        model.open(scope: .root)
        model.handle(.moveDown)
        #expect(model.selectedRowID == "cmd.b")
        model.query = "@"
        #expect(model.query == "")
        #expect(model.scopeChips.map(\.scope) == [Self.tabs])
        model.handle(.back)
        #expect(model.scopeChips.isEmpty)
        #expect(model.query == "")
        #expect(model.selectedRowID == "cmd.b")
    }

    @Test func keywordShowsAHintAndTabEnters() async {
        let log = Log()
        let model = makeModel(log: log)
        model.open(scope: .root)
        model.query = "tabs"
        #expect(model.keywordHint?.title == "Tabs")
        await model.settle()
        model.handle(.openActions)
        #expect(model.scopeChips.map(\.title) == ["Tabs"])
        #expect(model.keywordHint == nil)
        model.handle(.back)
        #expect(model.query == "")
    }

    @Test func tabDrillsIntoTheRowActionsWhenThatPrototypeIsOn() {
        let log = Log()
        let model = makeModel(log: log, itemActionsAsScope: true)
        model.open(scope: Self.tabs)
        model.handle(.openActions)
        #expect(model.scopeChips.map(\.title) == ["Tabs", "Actions"])
        #expect(model.rows.map(\.item.title) == ["Run", "Close"])
        model.handle(.moveDown)
        model.handle(.submit)
        #expect(log.events == ["dismiss", "close:tab.previous"])
    }

    @Test func tabOpensTheActionsMenuByDefault() {
        let log = Log()
        let model = makeModel(log: log)
        model.open(scope: Self.tabs)
        model.handle(.openActions)
        #expect(model.actionsMenu?.itemID == "tab.previous")
        #expect(model.scopeChips.count == 1)
    }

    @Test func aChipClickPopsToItsLevel() {
        let log = Log()
        let model = makeModel(log: log, itemActionsAsScope: true)
        model.open(scope: Self.tabs)
        model.handle(.openActions)
        #expect(model.depth == 3)
        model.pop(to: 0)
        #expect(model.depth == 1)
        #expect(model.pageTitle == "Commands")
    }
}
