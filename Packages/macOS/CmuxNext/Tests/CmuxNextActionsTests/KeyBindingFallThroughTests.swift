import AppKit
import CmuxNextActions
import Testing

/// R88: a binding meant for the current context that cannot run (its
/// `when` holds, its action is unavailable or disabled) ends the search:
/// the key never falls through to a less specific binding on the same key
/// (Cmd-Shift-G in a page must not group the selected workspaces when React
/// Grab is unavailable). A binding with no `when` that cannot run still
/// lets the key reach an earlier entry, so a disabled general action never
/// eats a key.
@MainActor
@Suite struct KeyBindingFallThroughTests {
    static let shiftG = Shortcut("g", modifiers: [.command, .shift])
    static let page = KeyContext([KeyContext.surfaceKind: .string("page"), "browserFocused": .bool(true)])
    static let terminal = KeyContext([KeyContext.surfaceKind: .string("terminal"), "terminalFocused": .bool(true)])

    @Test func anUnavailableBindingForThisContextNeverFallsThrough() {
        let table = KeyBindingTable([
            KeyBinding(keys: [Self.shiftG], command: "groupSelectedWorkspaces"),
            KeyBinding(keys: [Self.shiftG], command: "toggleReactGrab", when: .has("browserFocused")),
        ])
        let runnable = { (id: ActionID) in id != "toggleReactGrab" }
        let inPage = table.resolve([Self.shiftG], in: Self.page, isRunnable: runnable)
        #expect(inPage.winner == nil, "the page's own binding is unavailable: nothing runs")
        #expect(inPage.candidates.map(\.verdict) == [.notRunnable, .shadowed])
        #expect(table.resolve([Self.shiftG], in: Self.terminal, isRunnable: runnable).winner?.command == "groupSelectedWorkspaces")
    }

    @Test func aDisabledGeneralBindingStillFallsThrough() {
        let table = KeyBindingTable([
            KeyBinding(keys: [Self.shiftG], command: "older"),
            KeyBinding(keys: [Self.shiftG], command: "disabledGeneral"),
        ])
        let winner = table.resolve([Self.shiftG], in: Self.page) { $0 != "disabledGeneral" }.winner
        #expect(winner?.command == "older")
    }

    /// The address bar has its own bit (R88): a binding that requires it
    /// wins only there.
    @Test func theOmnibarHasItsOwnContextBit() {
        #expect(ActionContext.keyNames.contains { $0.1 == "omnibarFocused" })
        #expect(KeyContext(bits: [.omnibarFocused])["omnibarFocused"] == .bool(true))
        #expect(!ActionContext.focusBits.isDisjoint(with: .omnibarFocused), "a window's focus decides it")
    }
}
