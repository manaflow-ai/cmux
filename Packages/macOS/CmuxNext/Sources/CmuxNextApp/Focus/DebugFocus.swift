import AppKit
import CmuxNextSettings

/// `debug.focus`: per window, the coordinator state next to what AppKit,
/// Ghostty and the layout actually show, and whether they agree
/// (plans/cmux-next/focus.md section 6). Pane and tab ids match
/// `debug.surfaces` and the compat tree.
enum DebugFocus {
    static func report(services: AppServices) -> JSONValue {
        let ghostty = services.cache.focusedTerminalTabs
        let windows = services.windows.controllers.map { window(of: $0, ghostty: ghostty) }
        let context = services.registry.context
        return .object([
            "windows": .array(windows),
            "ghostty_focused_tabs": .array(ghostty.map(JSONValue.string)),
            "key_window": NSApp.keyWindow.map { .string(String(describing: type(of: $0))) } ?? .null,
            "app_active": .bool(NSApp.isActive),
            "context": .object([
                "terminal_focused": .bool(context.contains(.terminalFocused)),
                "browser_focused": .bool(context.contains(.browserFocused)),
                "palette_open": .bool(context.contains(.paletteOpen)),
            ]),
            "consistent": .bool(windows.allSatisfy { $0["consistent"]?.boolValue == true }),
        ])
    }

    private static func window(of controller: WindowController, ghostty: [String]) -> JSONValue {
        let state = controller.focus.state
        let resolved = state.resolved
        let window = controller.window
        let isKey = window?.isKeyWindow ?? false
        let actual = FocusResponderClassifier.classify(window?.firstResponder, in: controller)
        let layoutFocus = controller.content?.layoutModel.focusedPane?.rawValue
        let problems = mismatches(state: state, actual: actual, isKey: isKey, layoutFocus: layoutFocus,
                                  ghostty: ghostty, controller: controller)
        return .object([
            "id": .string(controller.state.id),
            "workspace": state.topology.workspace.map(JSONValue.string) ?? .null,
            "is_key": .bool(isKey),
            "model": .object([
                "pane": state.pane.map(JSONValue.string) ?? .null,
                "target": .string(String(describing: state.target)),
                "resolved": .string(resolved.kind),
                "resolved_pane": resolved.pane.map(JSONValue.string) ?? .null,
                "resolved_tab": resolved.tab.map(JSONValue.string) ?? .null,
                "overlays": .array(state.overlays.map { .string($0.rawValue) }),
                "expectation": state.expectation.map { .string(String(describing: $0.key)) } ?? .null,
                "dragging": .bool(state.drag != nil),
                "browser_focus_mode": .array(state.browserFocusMode.sorted().map(JSONValue.string)),
                "window_key": .bool(state.windowKey),
                "generation": .number(Double(state.generation)),
            ]),
            "topology": .array(state.topology.panes.map { pane in
                .object([
                    "pane": .string(pane.id),
                    "selected": pane.selected.map(JSONValue.string) ?? .null,
                    "tabs": .array(pane.tabs.map { .string("\($0.id):\($0.kind.rawValue)") }),
                ])
            }),
            "appkit": .object([
                "first_responder": window?.firstResponder.map { .string(String(describing: type(of: $0))) } ?? .null,
                "classified": .string(FocusResponderClassifier.describe(actual)),
                "child_window_page": controller.focusApplier.focusedChildWindowPageID.map(JSONValue.string) ?? .null,
            ]),
            "layout_focused_pane": layoutFocus.map(JSONValue.string) ?? .null,
            "recent_events": .array(controller.focus.recent.suffix(12).map(JSONValue.string)),
            "mismatches": .array(problems.map(JSONValue.string)),
            "consistent": .bool(problems.isEmpty),
        ])
    }

    /// Model == AppKit == Ghostty == layout. Ghostty focus is expected only
    /// for the key window's terminal. Overlays and child-window pages hold
    /// keys outside this window's responder chain, so only their model side
    /// is checked.
    private static func mismatches(state: FocusState, actual: FocusEvent.Responder, isKey: Bool, layoutFocus: String?,
                                   ghostty: [String], controller: WindowController) -> [String] {
        var problems: [String] = []
        let resolved = state.resolved
        if let pane = state.pane, layoutFocus != pane { problems.append("layout focus \(layoutFocus ?? "nil") != model pane \(pane)") }
        let expected: FocusEvent.Responder? = switch resolved {
        case .terminal(let pane, _): .content(pane: pane)
        case .browserPage(let pane, _):
            controller.focusApplier.focusedChildWindowPageID == nil ? .content(pane: pane) : nil
        case .addressBar(let pane, _): .addressBar(pane: pane)
        case .findBar(let pane, _): .findBar(pane: pane)
        case .sidebar: .sidebar
        case .sidebarField: .sidebarField
        case .textField: .textField
        case .emptyPane, .overlay, .none: nil
        }
        if let expected, expected != actual {
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
