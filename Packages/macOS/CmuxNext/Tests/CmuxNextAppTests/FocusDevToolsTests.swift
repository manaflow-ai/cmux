import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// A page's docked DevTools is a separate keyboard target inside its pane
/// (plans/cmux-next/focus.md section 4): the focus model, the key tiers and
/// the chord table know it.
@MainActor
struct FocusDevToolsTests {
    typealias R = FocusReducerTests
    typealias K = KeyInterceptionTests

    static let devTools = R.run([.focusPane("b", source: .mouse), .focusTarget(.devTools, source: .keyboard)], from: R.loaded()).0

    @Test func devToolsIsABrowserTargetInsideThePane() {
        #expect(Self.devTools.resolved == .devTools(pane: "b", tab: "b1"))
        #expect(Self.devTools.context == FocusState.Context(browser: true))
        #expect(!Self.devTools.resolved.isTextInput)
        #expect(Self.devTools.resolved.isDevTools)
        #expect(BrowserChordTable.isBrowserContext(Self.devTools.resolved))
    }

    @Test func devToolsTargetNeedsABrowserTab() {
        let state = R.run([.focusTarget(.devTools, source: .keyboard)], from: R.loaded()).0
        #expect(state.resolved == .terminal(pane: "a", tab: "t1"))
    }

    @Test func aClickInDevToolsIsAcceptedAndMovesThePane() {
        let (state, effects) = R.run([.responder(.devTools(pane: "b"), source: .mouse)], from: R.loaded())
        #expect(state.resolved == .devTools(pane: "b", tab: "b1"))
        #expect(!effects.contains(.moveResponder(.browserPage(pane: "b", tab: "b1"))))
    }

    @Test func clickingThePageLeavesDevTools() {
        let state = R.run([.responder(.content(pane: "b"), source: .mouse)], from: Self.devTools).0
        #expect(state.resolved == .browserPage(pane: "b", tab: "b1"))
    }

    @Test func anotherPaneLeavesDevToolsAndComingBackIsThePage() {
        var state = R.run([.focusPane("a", source: .keyboard)], from: Self.devTools).0
        #expect(state.resolved == .terminal(pane: "a", tab: "t1"))
        state = R.run([.focusPane("b", source: .keyboard)], from: state).0
        #expect(state.resolved == .browserPage(pane: "b", tab: "b1"))
    }

    /// Content chords (Copy, Reload) belong to the DevTools frontend, not
    /// the page behind it; navigation (Ctrl-Tab, Cmd-1) still runs.
    @Test func contentTierDoesNotRunInDevTools() {
        #expect(!KeyRouter.allows(.content, focus: Self.devTools))
        #expect(KeyRouter.allows(.navigation, focus: Self.devTools))
        #expect(KeyRouter.allows(.system, focus: Self.devTools))
    }

    @Test func ctrlTabSwitchesTabsFromDevTools() throws {
        let services = BrowserChordTableTests.services()
        services.registry.context.insert(.browserFocused)
        let event = try K.key("\t", keyCode: 48, [.control])
        let candidate = try #require(services.keyRouter.candidate(for: event, focus: Self.devTools))
        #expect(candidate.id == "nextSurface")
        #expect(KeyRouter.intercepts(candidate, focus: Self.devTools, keyWindow: .content))
    }

    @Test func devToolsShortcutsMatchChrome() throws {
        let registry = ActionBindingCoverageTests.boundServices().registry
        #expect(registry.effectiveShortcut(for: "toggleBrowserDeveloperTools") == Shortcut("i", modifiers: [.command, .option]))
        #expect(registry.effectiveShortcut(for: "showBrowserJavaScriptConsole") == Shortcut("j", modifiers: [.command, .option]))
        #expect(registry.effectiveShortcut(for: "inspectBrowserElement") == Shortcut("c", modifiers: [.command, .option]))
    }
}
