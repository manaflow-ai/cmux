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

/// Window actions decode, and the `set_window_title` read stays sound: it
/// reads the `set_title` member (ghostty.h has no `set_window_title`
/// member; apprt's SetTitle payload is one C string), so that member must
/// stay exactly one C string pointer (a union member starts at offset 0).
@Suite struct GhosttyWindowActionDecodeTests {
    @Test func windowActionsDecode() {
        #expect(GhosttyActionRouteDecodeTests.host(GHOSTTY_ACTION_GOTO_WINDOW) { $0.goto_window = GHOSTTY_GOTO_WINDOW_NEXT } == .gotoWindow(next: true))
        #expect(GhosttyActionRouteDecodeTests.host(GHOSTTY_ACTION_GOTO_WINDOW) { $0.goto_window = GHOSTTY_GOTO_WINDOW_PREVIOUS } == .gotoWindow(next: false))
        #expect(GhosttyActionRouteDecodeTests.host(GHOSTTY_ACTION_MOVE_TAB_TO_NEW_WINDOW) == .moveTabToNewWindow)
    }

    @Test func theSetTitleMemberIsOneStringPointerAtTheStartOfTheUnion() {
        #expect(MemoryLayout<ghostty_action_set_title_s>.size == MemoryLayout<UnsafePointer<CChar>?>.size)
        #expect(MemoryLayout<ghostty_action_set_title_s>.offset(of: \.title) == 0)
    }
}
