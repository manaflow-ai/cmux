import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// R85 (Lawrence): Ctrl-N / Ctrl-J move down and Ctrl-P / Ctrl-K move up in
/// every list-like control (comboboxes, autocomplete, menus and pickers in
/// pages, the sidebar list and its search results). One mechanism: the
/// `listFocus` context key and the default bindings list.next /
/// list.previous; never in a terminal or a plain text field.
@MainActor
struct ListNavigationKeyTests {
    typealias M = KeyOwnershipMatrixTests
    typealias K = KeyInterceptionTests

    static let list = KeyRouter.Facts(listFocus: true)

    static func keys() throws -> [(NSEvent, ActionID)] {
        [(try K.key("n", keyCode: 45, [.control]), "list.next"), (try K.key("j", keyCode: 38, [.control]), "list.next"),
         (try K.key("p", keyCode: 35, [.control]), "list.previous"), (try K.key("k", keyCode: 40, [.control]), "list.previous")]
    }

    @Test func listKeysMoveTheSelectionWhereAListHasFocus() throws {
        let router = M.services().keyRouter!
        let surfaces: [(String, FocusState, KeyRouter.Facts)] = [
            ("new tab agent dropdown (agent page combobox)", M.focused(.agent, tab: "local-agent:1"), Self.list),
            ("React page menu", M.focused(.page, tab: "local-page:settings:1"), Self.list),
            ("web page combobox", M.page, Self.list),
            ("sidebar list", M.focused(.terminal, tab: "t1", target: .sidebar(keyboard: true)), KeyRouter.Facts()),
            ("sidebar search results", M.focused(.terminal, tab: "t1", target: .sidebarField), KeyRouter.Facts()),
        ]
        for (name, focus, facts) in surfaces {
            for (event, action) in try Self.keys() {
                guard case .run(let candidate) = router.decide(event, focus: focus, keyWindow: .content, facts: facts) else {
                    Issue.record("\(name) \(event.charactersIgnoringModifiers ?? ""): not run"); continue
                }
                #expect(candidate.id == action, "\(name)")
            }
        }
    }

    @Test func terminalsAndPlainFieldsKeepTheirControlKeys() throws {
        let router = M.services().keyRouter!
        for focus in [M.terminal, M.focused(.agent, tab: "local-agent:1"), M.focused(.terminal, tab: "t1", target: .textField)] {
            for (event, action) in try Self.keys() {
                if case .run(let candidate) = router.decide(event, focus: focus, keyWindow: .content, facts: KeyRouter.Facts()) {
                    #expect(candidate.id != action, "\(focus.resolved)")
                }
            }
        }
    }

    @Test func theDefaultsAreListedEditableEntries() {
        let bindings = KeybindingReports.list(["command": "list.next"], registry: M.services().registry)
        let keys = (bindings["bindings"]?.arrayValue ?? []).compactMap { $0["key"]?.stringValue }
        #expect(Set(keys) == ["ctrl+n", "ctrl+j"])
        #expect((bindings["bindings"]?.arrayValue ?? []).allSatisfy { $0["when"]?.stringValue == "listFocus" })
        let context = KeyRouter.keyContext(for: M.page, appContext: [], facts: Self.list)
        #expect(context[KeyContext.listFocus] == .bool(true))
    }
}
