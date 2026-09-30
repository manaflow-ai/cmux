import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The coordinator's queue (effects after the reducer, no re-entry, echo
/// suppression) and the key routing tiers (plans/cmux-next/focus.md 4, 5).
@MainActor
struct FocusCoordinatorTests {
    /// Records effects; optionally raises events while applying, like a
    /// `makeFirstResponder` echo or a selection echo would.
    final class Applier: FocusEffectApplying {
        weak var coordinator: FocusCoordinator?
        var batches: [[FocusEffect]] = []
        var raiseWhileApplying: [FocusEvent] = []
        var echoResponder: FocusEvent.Responder?
        var sawApplyingState: [FocusState] = []

        func apply(_ effects: [FocusEffect], state: FocusState) {
            batches.append(effects)
            sawApplyingState.append(state)
            if let echoResponder { coordinator?.responderDidChange(echoResponder, source: .programmatic) }
            let raise = raiseWhileApplying
            raiseWhileApplying = []
            for event in raise { coordinator?.send(event) }
        }
    }

    static func make() -> (FocusCoordinator, Applier) {
        let coordinator = FocusCoordinator()
        let applier = Applier()
        applier.coordinator = coordinator
        coordinator.applier = applier
        return (coordinator, applier)
    }

    @Test func eventsRaisedWhileApplyingAreReducedAfterwardsInOrder() {
        let (coordinator, applier) = Self.make()
        applier.raiseWhileApplying = [.focusPane("c", source: .keyboard)]
        coordinator.send(.topology(FocusReducerTests.topology()))
        #expect(applier.batches.count == 2)
        // The first batch saw the state of the first event only.
        #expect(applier.sawApplyingState.first?.pane == "a")
        #expect(coordinator.state.pane == "c")
    }

    @Test func applierResponderEchoesAreDropped() {
        let (coordinator, applier) = Self.make()
        applier.echoResponder = .sidebarField
        coordinator.send(.topology(FocusReducerTests.topology()))
        #expect(coordinator.state.resolved == .terminal(pane: "a", tab: "t1"))
        #expect(!coordinator.recent.contains { $0.contains("sidebarField") })
    }

    @Test func beginIntentThenLateExpectationLosesToAClick() {
        let (coordinator, _) = Self.make()
        coordinator.send(.topology(FocusReducerTests.topology()))
        let intent = coordinator.beginIntent()
        coordinator.responderDidChange(.content(pane: "b"), source: .mouse)
        coordinator.expect(.surface("s-t3"), generation: intent)
        #expect(coordinator.state.pane == "b")
    }

    // MARK: Key tiers

    @Test func catalogTiersMatchTheRoutingTable() {
        let registry = ActionRegistry.standard()
        #expect(registry.keyTier(for: "quit") == .system)
        #expect(registry.keyTier(for: "commandPalette") == .system)
        #expect(registry.keyTier(for: "toggleBrowserFocusMode") == .system)
        #expect(registry.keyTier(for: "focusLeft") == .navigation)
        #expect(registry.keyTier(for: "nextSurface") == .navigation)
        #expect(registry.keyTier(for: "splitRight") == .navigation)
        #expect(registry.keyTier(for: "focusBrowserAddressBar") == .navigation)
        #expect(registry.keyTier(for: "terminalCopy") == .content)
        #expect(registry.keyTier(for: "terminalPaste") == .content)
        #expect(registry.keyTier(for: "browserReload") == .content)
        registry.setKeyTierOverride(.content, for: "splitRight")
        #expect(registry.keyTier(for: "splitRight") == .content)
    }

    @Test func routerTierGatesFollowTheFocus() {
        var terminal = FocusReducerTests.loaded()
        #expect(KeyRouter.allows(.content, focus: terminal))
        terminal = FocusReducer.reduce(terminal, .responder(.sidebarField, source: .mouse)).0
        #expect(!KeyRouter.allows(.content, focus: terminal), "Cmd-C in the sidebar search belongs to the field")
        #expect(KeyRouter.allows(.navigation, focus: terminal))

        var page = FocusReducer.reduce(FocusReducerTests.loaded(), .focusPane("b", source: .mouse)).0
        page = FocusReducer.reduce(page, .toggleBrowserFocusMode(tab: nil)).0
        #expect(KeyRouter.allows(.system, focus: page))
        #expect(!KeyRouter.allows(.navigation, focus: page), "focus mode gives the page navigation chords")
        #expect(!KeyRouter.allows(.content, focus: page))
    }

    /// Cmd-C with the sidebar search focused must not copy from the
    /// terminal (R3): the registry does not take it and the context has no
    /// terminal bit.
    @Test func copyInASidebarFieldIsNotTheTerminalCopy() throws {
        let services = ActionBindingCoverageTests.boundServices()
        var ran: [ActionID] = []
        services.registry.bind("terminalCopy", invoke: { _ in ran.append("terminalCopy") })
        services.registry.context.insert(.terminalFocused)
        let focus = FocusReducer.reduce(FocusReducerTests.loaded(), .responder(.sidebarField, source: .mouse)).0
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 1, windowNumber: 0,
                                                  context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        #expect(!services.keyRouter.routeKeyEquivalent(event, focus: focus))
        #expect(ran.isEmpty)
        #expect(services.keyRouter.routeKeyEquivalent(event, focus: FocusReducerTests.loaded()))
        #expect(ran == ["terminalCopy"])
    }
}

/// Menu key equivalents follow the router's tiers (the menu gap).
struct MenuKeyEquivalentTierTests {
    @Test func menuChordsFollowTheKeyWindowFocus() {
        let terminal = FocusReducerTests.loaded()
        #expect(KeyRouter.allowsMenu(.content, focus: terminal, keyWindow: .content))
        let field = FocusReducer.reduce(terminal, .responder(.sidebarField, source: .mouse)).0
        #expect(!KeyRouter.allowsMenu(.content, focus: field, keyWindow: .content))
        #expect(KeyRouter.allowsMenu(.navigation, focus: field, keyWindow: .content))
        var page = FocusReducer.reduce(terminal, .focusPane("b", source: .mouse)).0
        page = FocusReducer.reduce(page, .toggleBrowserFocusMode(tab: nil)).0
        #expect(!KeyRouter.allowsMenu(.navigation, focus: page, keyWindow: .content), "focus mode: the page keeps Cmd-D")
        #expect(KeyRouter.allowsMenu(.system, focus: page, keyWindow: .content))
        #expect(!KeyRouter.allowsMenu(.content, focus: terminal, keyWindow: .textPanel), "palette or sheet field keeps Copy")
        #expect(KeyRouter.allowsMenu(.content, focus: page, keyWindow: .other))
    }

    @MainActor
    @Test func appInstallsTheRouterAsTheMenuGate() {
        let services = ActionBindingCoverageTests.boundServices()
        #expect(services.registry.menuKeyEquivalentGate != nil)
    }
}
