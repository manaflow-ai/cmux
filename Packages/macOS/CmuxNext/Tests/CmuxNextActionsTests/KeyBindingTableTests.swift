import AppKit
import CmuxNextActions
import Testing

/// The binding table (plans/cmux-next/keybindings.md section 4): the last
/// entry whose `when` holds and whose action can run wins; the catalog's
/// defaults keep today's "most specific wins"; user entries come after
/// defaults; the tab-switch defaults follow their actions.
@MainActor
@Suite struct KeyBindingTableTests {
    static let cmdR = Shortcut("r")
    static let terminal = KeyContext([KeyContext.surfaceKind: .string("terminal"), "terminalFocused": .bool(true)])
    static let page = KeyContext([KeyContext.surfaceKind: .string("page"), "browserFocused": .bool(true)])

    @Test func theLastApplicableRunnableEntryWinsWithVerdicts() {
        let table = KeyBindingTable([
            KeyBinding(keys: [Self.cmdR], command: "general"),
            KeyBinding(keys: [Self.cmdR], command: "inPage", when: .has("browserFocused")),
            KeyBinding(keys: [Self.cmdR], command: "disabled"),
        ])
        let inPage = table.resolve([Self.cmdR], in: Self.page) { $0 != "disabled" }
        #expect(inPage.winner?.command == "inPage")
        #expect(inPage.candidates.map(\.verdict) == [.notRunnable, .won, .shadowed])
        let inTerminal = table.resolve([Self.cmdR], in: Self.terminal) { $0 != "disabled" }
        #expect(inTerminal.winner?.command == "general")
        #expect(inTerminal.candidates.map(\.verdict) == [.notRunnable, .whenFalse, .won])
    }

    @Test func whenClausesEvaluateLikeTheGrammar() {
        let context = KeyContext([
            KeyContext.surfaceKind: .string("page"), "page.host": .string("github.com"), "pinned": .strings(["github.com"]),
            "columns.count": .number(2), "terminalFocused": .bool(false),
        ])
        #expect(WhenClause.equals(KeyContext.surfaceKind, .string("page")).evaluate(context))
        #expect(WhenClause.notEquals(KeyContext.surfaceKind, .string("terminal")).evaluate(context))
        #expect(WhenClause.notEquals("missing", .string("x")).evaluate(context), "a missing key differs")
        #expect(!WhenClause.equals("missing", .string("x")).evaluate(context))
        #expect(WhenClause.equals("columns.count", .number(2)).evaluate(context))
        #expect(WhenClause.matches("page.host", pattern: "^git.*\\.com$").evaluate(context))
        #expect(WhenClause.isIn("page.host", listKey: "pinned").evaluate(context))
        #expect(!WhenClause.has("terminalFocused").evaluate(context))
        #expect(WhenClause.or([.has("terminalFocused"), .not(.has("missing"))]).evaluate(context))
        #expect(!WhenClause.and([.constant(true), .has("terminalFocused")]).evaluate(context))
    }

    @Test func requiredContextBecomesTheWhenClause() {
        #expect(WhenClause.requiring([]) == nil)
        #expect(WhenClause.requiring([.terminalFocused]) == .has("terminalFocused"))
        #expect(KeyContext(bits: [.browserFocused, .signedIn]).bits == [.browserFocused, .signedIn])
    }

    /// Rename Tab (no context) and Reload (browser) share Cmd-R: the table
    /// orders the more specific default later, so Reload wins in a page and
    /// Rename Tab elsewhere, as before the table existed.
    @Test func catalogDefaultsKeepTheMostSpecificWinner() {
        let registry = ActionRegistry(catalog: [
            ShortcutAssessmentTests.action("rename", Self.cmdR),
            ShortcutAssessmentTests.action("reload", Self.cmdR, requires: [.browserFocused]),
        ])
        for id: ActionID in ["rename", "reload"] { registry.bind(id, invoke: { _ in }) }
        let table = RegistryKeyBindings(registry).table
        let bits = { (context: KeyContext) in { (id: ActionID) in RegistryKeyBindings(registry).canPerform(id, in: context.bits) } }
        #expect(table.resolve([Self.cmdR], in: Self.page, isRunnable: bits(Self.page)).winner?.command == "reload")
        #expect(table.resolve([Self.cmdR], in: Self.terminal, isRunnable: bits(Self.terminal)).winner?.command == "rename")
    }

    /// A user binding is a later layer: it wins over a more specific default
    /// on the same key. Writing an action's default key into cmux.json
    /// changes nothing.
    @Test func userEntriesComeAfterDefaults() {
        let registry = ActionRegistry(catalog: [
            ShortcutAssessmentTests.action("mine", Shortcut("y")),
            ShortcutAssessmentTests.action("reload", Self.cmdR, requires: [.browserFocused]),
            ShortcutAssessmentTests.action("rename", Self.cmdR),
        ])
        for id: ActionID in ["mine", "reload", "rename"] { registry.bind(id, invoke: { _ in }) }
        registry.setShortcutOverride(Self.cmdR, for: "rename")
        let runnable = { (id: ActionID) in RegistryKeyBindings(registry).canPerform(id, in: Self.page.bits) }
        #expect(RegistryKeyBindings(registry).table.resolve([Self.cmdR], in: Self.page, isRunnable: runnable).winner?.command == "reload",
                "the default key written out stays a default")
        registry.setShortcutOverride(Self.cmdR, for: "mine")
        let winner = RegistryKeyBindings(registry).table.resolve([Self.cmdR], in: Self.page, isRunnable: runnable).winner
        #expect(winner?.command == "mine")
        #expect(winner?.source == .user)
    }

    @Test func tabSwitchDefaultsFollowTheirActions() {
        let registry = ActionRegistry(catalog: [
            ShortcutAssessmentTests.action("nextSurface", Shortcut("]", modifiers: [.command, .shift])),
            ShortcutAssessmentTests.action("prevSurface", Shortcut("[", modifiers: [.command, .shift])),
        ])
        for id: ActionID in ["nextSurface", "prevSurface"] { registry.bind(id, invoke: { _ in }) }
        let ctrlTab = Shortcut("\t", modifiers: [.control])
        let agent = KeyContext([KeyContext.surfaceKind: .string("agent")])
        let copyMode = KeyContext([KeyContext.surfaceKind: .string("terminal"), KeyContext.terminalCopyMode: .bool(true)])
        let all = { (_: ActionID) in true }
        #expect(RegistryKeyBindings(registry).table.resolve([ctrlTab], in: agent, isRunnable: all).winner?.command == "nextSurface")
        #expect(RegistryKeyBindings(registry).table.resolve([ctrlTab], in: Self.terminal, isRunnable: all).winner == nil, "Ghostty keeps it")
        #expect(RegistryKeyBindings(registry).table.resolve([ctrlTab], in: copyMode, isRunnable: all).winner?.command == "nextSurface")
        registry.setShortcutOverride(nil, for: "nextSurface")
        #expect(RegistryKeyBindings(registry).table.resolve([ctrlTab], in: agent, isRunnable: all).winner == nil, "unbinding removes it")
    }

    @Test func chordPrefixesContinueOnlyWhereAnEntryCanRun() {
        let ctrlK = Shortcut("k", modifiers: [.control])
        let table = KeyBindingTable([
            KeyBinding(keys: [ctrlK, Shortcut("s", modifiers: [])], command: "save", when: .has("terminalFocused")),
        ])
        #expect(table.continues([ctrlK], in: Self.terminal) { _ in true })
        #expect(!table.continues([ctrlK], in: Self.page) { _ in true })
        #expect(table.entries(after: [ctrlK]).count == 1)
        #expect(table.resolve([ctrlK, Shortcut("s", modifiers: [])], in: Self.terminal) { _ in true }.winner?.command == "save")
    }
}
