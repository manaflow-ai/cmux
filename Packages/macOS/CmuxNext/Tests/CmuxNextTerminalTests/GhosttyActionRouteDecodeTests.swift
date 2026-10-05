import GhosttyNextKit
@testable import CmuxNextTerminal
import Testing

/// The Ghostty actions cmux routes to its catalog are decoded into host
/// actions (GHOSTTY-CONFIG "Keybinds"); an undecoded action makes Ghostty
/// treat its keybind as not performed.
@Suite struct GhosttyActionRouteDecodeTests {
    static func host(_ tag: ghostty_action_tag_e, _ fill: (inout ghostty_action_u) -> Void = { _ in }) -> TerminalHostAction? {
        var action = ghostty_action_s()
        action.tag = tag
        fill(&action.action)
        if case .host(let host)? = GhosttyActionDecoder.decode(action) { return host }
        return nil
    }

    @Test func windowAndTabActionsDecode() {
        #expect(Self.host(GHOSTTY_ACTION_TOGGLE_VISIBILITY) == .toggleVisibility)
        #expect(Self.host(GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW) == .toggleTabOverview)
        #expect(Self.host(GHOSTTY_ACTION_PRESENT_TERMINAL) == .presentTerminal)
    }

    @Test func titlePromptsDecodeByKind() {
        #expect(Self.host(GHOSTTY_ACTION_PROMPT_TITLE) { $0.prompt_title = GHOSTTY_PROMPT_TITLE_SURFACE } == .promptTitle)
        #expect(Self.host(GHOSTTY_ACTION_PROMPT_TITLE) { $0.prompt_title = GHOSTTY_PROMPT_TITLE_TAB } == .promptTitle)
        #expect(Self.host(GHOSTTY_ACTION_PROMPT_TITLE) { $0.prompt_title = GHOSTTY_PROMPT_TITLE_WINDOW } == .promptWindowTitle)
    }

    @Test func setWindowTitleCarriesTheTitle() {
        let decoded = "build".withCString { title in Self.host(GHOSTTY_ACTION_SET_WINDOW_TITLE) { $0.set_title.title = title } }
        #expect(decoded == .setWindowTitle("build"))
    }
}
