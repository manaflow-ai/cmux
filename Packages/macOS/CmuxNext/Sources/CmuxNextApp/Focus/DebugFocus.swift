import AppKit
import CmuxNextSettings
import CmuxNextFocus
import CmuxNextPalette

/// `debug.focus`: per window, the coordinator state next to what AppKit, Ghostty and the layout show, whether they
/// agree (plans/cmux-next/focus.md section 6), and its key holds: the New Tab hold and the creation hold (`creation_hold`
/// open now, `creation_hold_end` how the last one ended), so a held key names its holder. Pane and tab ids match
/// `debug.surfaces` and the compat tree.
enum DebugFocus {
    static func report(services: AppServices) -> JSONValue {
        let ghostty = services.cache.focusedTerminalTabs
        let windows = services.windows.controllers.map { window(of: $0, ghostty: ghostty, creations: services.keyRouter.creationInputCoordinator) }
        let context = services.registry.context
        let windowProblems = WindowInvariants.problems(services.windows)
        return .object([
            "windows": .array(windows),
            "window_invariants": .array(windowProblems.map(JSONValue.string)),
            "ghostty_focused_tabs": .array(ghostty.map(JSONValue.string)),
            "key_window": NSApp.keyWindow.map { .string(String(describing: type(of: $0))) } ?? .null,
            "app_active": .bool(NSApp.isActive),
            "keyboard_given_back": keyboardGuard(services),
            // Windows whose keys wait for a New Tab field (NewTabInputCoordinator); never stays.
            "new_tab_key_log": .array(services.keyRouter.newTabInputCoordinator.log.map(JSONValue.string)),
            "new_tab_key_holds": .array(services.windows.controllers.filter {
                services.keyRouter.newTabInputCoordinator.isHolding(in: $0.window)
            }.map { .string($0.state.id) }),
            "context": .object([
                "terminal_focused": .bool(context.contains(.terminalFocused)),
                "browser_focused": .bool(context.contains(.browserFocused)),
                "agent_focused": .bool(context.contains(.agentPaneFocused)),
                "palette_open": .bool(context.contains(.paletteOpen)),
            ]),
            "palette": palette(services.palette),
            "consistent": .bool(windowProblems.isEmpty && windows.allSatisfy { $0["consistent"]?.boolValue == true }),
        ])
    }

    /// The open palette as drawn: its field's text, the model's query and the selected row, so a
    /// capture asserts what its still shows (an empty field over a set query is a failure).
    private static func palette(_ palette: PaletteController) -> JSONValue {
        guard let field = palette.visibleFieldText else { return ["open": .bool(false)] }
        let model = palette.model
        return ["open": .bool(true), "field": .string(field), "query": .string(model.query),
                "page": .string(model.pageTitle), "ranking": .bool(model.isRanking), "loading": .bool(model.isLoading),
                "selected": model.selectedItem.map { .string($0.actionID?.rawValue ?? $0.id) } ?? .null,
                "selected_title": model.selectedItem.map { .string($0.title) } ?? .null]
    }

    /// No-activate mode: how often the keyboard was given back, and the last time.
    private static func keyboardGuard(_ services: AppServices) -> JSONValue {
        guard let guardian = services.input.keyboardGuard else { return .null }
        let last = guardian.giveBacks.last.map { giveBack -> JSONValue in
            ["trigger": .string(giveBack.trigger.rawValue), "cause": .string(giveBack.cause), "restored_to": giveBack.restoredTo.map { JSONValue(Int($0)) } ?? .null]
        } ?? .null
        return ["count": JSONValue(guardian.giveBackCount), "last": last]
    }

    private static func window(of controller: WindowController, ghostty: [String], creations: CreationInputCoordinator) -> JSONValue {
        let state = controller.focus.state
        let resolved = state.resolved
        let window = controller.window
        let isKey = window?.isKeyWindow ?? false
        let actual = FocusResponderClassifier.classify(window?.firstResponder, in: controller)
        let layoutFocus = controller.content?.layoutModel.focusedPane?.rawValue
        // A top page covers the parked workspace, whose pane the model still names (InputInvariants.world).
        let problems = controller.shownTopPage != nil ? [] : mismatches(state: state, actual: actual, isKey: isKey, layoutFocus: layoutFocus,
                                                                        ghostty: ghostty, controller: controller)
        return .object([
            "id": .string(controller.state.id),
            "workspace": state.topology.workspace.map(JSONValue.string) ?? .null,
            "workspace_name": controller.content.map { .string($0.workspace.displayName) } ?? .null,
            "is_key": .bool(isKey),
            "creation_hold": .bool(creations.isHolding(in: window)), "creation_hold_end": creations.lastHoldEnd(in: window).map { .string(String(describing: $0)) } ?? .null,
            "model": .object([
                "pane": state.pane.map(JSONValue.string) ?? .null,
                "target": .string(String(describing: state.target)),
                "resolved": .string(resolved.kind),
                "resolved_pane": resolved.pane.map(JSONValue.string) ?? .null,
                "resolved_tab": resolved.tab.map(JSONValue.string) ?? .null,
                "overlays": .array(state.overlays.map { .string($0.rawValue) }),
                "expectation": state.expectation.map { .string(String(describing: $0.key)) } ?? .null,
                "dragging": .bool(state.isDragging),
                "browser_focus_mode": .array(state.browserFocusMode.sorted().map(JSONValue.string)),
                "window_key": .bool(state.windowKey),
                "sidebar_hidden": .bool(state.sidebarHidden),
                "generation": .number(Double(state.generation)),
            ]),
            "topology": .array(state.topology.panes.map { pane in
                let selectedIndex = pane.selected.flatMap { selected in pane.tabs.firstIndex { $0.id == selected } }
                return .object([
                    "pane": .string(pane.id),
                    "selected": pane.selected.map(JSONValue.string) ?? .null,
                    "selected_index": selectedIndex.map { .number(Double($0)) } ?? .null,
                    "tab_count": .number(Double(pane.tabs.count)),
                    "tabs": .array(pane.tabs.map { .string("\($0.id):\($0.kind.rawValue)") }),
                ])
            }),
            "appkit": .object([
                "first_responder": window?.firstResponder.map { .string(String(describing: type(of: $0))) } ?? .null,
                "classified": .string(FocusResponderClassifier.describe(actual)),
                "child_window_page": controller.focusApplier.focusedChildWindowPageID.map(JSONValue.string) ?? .null,
                "devtools_tab": controller.focusApplier.focusedDevToolsTabID.map(JSONValue.string) ?? .null,
            ]),
            "layout_focused_pane": layoutFocus.map(JSONValue.string) ?? .null,
            "recent_events": .array(controller.focus.recent.suffix(12).map(JSONValue.string)),
            "mismatches": .array(problems.map(JSONValue.string)),
            "consistent": .bool(problems.isEmpty),
        ])
    }

    /// Model == AppKit == Ghostty == layout. Ghostty focus is expected only
    /// for the key window's terminal. The expected responder is the input
    /// monitor's (W1), so the two never disagree: a child-window page or
    /// DevTools leaves this window no responder, an overlay is not checked.
    private static func mismatches(state: FocusState, actual: FocusEvent.Responder, isKey: Bool, layoutFocus: String?,
                                   ghostty: [String], controller: WindowController) -> [String] {
        var problems: [String] = []
        let resolved = state.resolved
        if let pane = state.pane, layoutFocus != pane { problems.append("layout focus \(layoutFocus ?? "nil") != model pane \(pane)") }
        let childPage = controller.focusApplier.focusedChildWindowPageID == nil ? nil : resolved.tab
        if let expected = InputInvariants.expectedResponder(resolved, childPage: childPage), expected != actual {
            problems.append("appkit \(FocusResponderClassifier.describe(actual)) != model \(resolved.kind)")
        }
        let ownTabs = Set(controller.content?.panes.values.compactMap(\.currentTabKey) ?? [])
        let focusedHere = ghostty.filter(ownTabs.contains)
        if case .terminal(_, let tab) = resolved, isKey {
            if focusedHere != [tab] { problems.append("ghostty focused \(focusedHere) != [\(tab)]") }
        } else if !focusedHere.isEmpty {
            problems.append("ghostty focused \(focusedHere) while model is \(resolved.kind)\(isKey ? "" : " (window not key)")")
        }
        return problems
    }
}
