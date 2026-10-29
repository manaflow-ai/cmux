import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextFocus
import CmuxNextInputModel
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextControl
import CmuxNextOracle
#endif

/// Reads the live combined input state into an `InputObservation`: each
/// window's focus model next to AppKit's first responder and key window,
/// Ghostty's focused surfaces, the layout focus and Chromium page focus.
/// Main actor, read-only, cheap (no layout, no IO).
enum InputObservationBuilder {
    static func observe(_ services: AppServices) -> InputObservation {
        let ghostty = Set(services.cache.focusedTerminalTabs)
        let controllers = services.windows.controllers
        let context = services.registry.context
        return InputObservation(
            windows: controllers.map { window(of: $0, ghostty: ghostty) },
            keyWindow: keyWindow(controllers),
            paletteOpen: context.contains(.paletteOpen),
            activeWindow: services.windows.active?.state.id,
            context: FocusState.Context(terminal: context.contains(.terminalFocused), browser: context.contains(.browserFocused),
                                     agent: context.contains(.agentPaneFocused))
        )
    }

    static func window(of controller: WindowController, ghostty: Set<String>) -> InputObservation.Window {
        let window = controller.window
        var presented: [String: String] = [:]
        var childWindowTabs: [String] = []
        // A cmux page's Chromium tab has its own id; the model knows the page by its tab key.
        var pageTabKeys: [String: String] = [:]
        for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
            guard let key = pane.currentTabKey else { continue }
            presented[pane.paneKey] = key
            if let tab = pane.currentContent?.childWindowTab { childWindowTabs.append(key); pageTabKeys[tab.id.rawValue] = key }
        }
        return InputObservation.Window(
            id: controller.state.id,
            model: controller.focus.state,
            responder: FocusResponderClassifier.classify(window?.firstResponder, in: controller),
            responderClass: window?.firstResponder.map { String(describing: type(of: $0)) },
            isKey: window?.isKeyWindow ?? false,
            layoutFocus: controller.content?.layoutModel.focusedPane?.rawValue,
            ghosttyFocused: presented.values.filter(ghostty.contains).sorted(),
            childPage: controller.focusApplier.focusedChildWindowPageID.map { pageTabKeys[$0] ?? $0 },
            presented: presented,
            childWindowTabs: childWindowTabs.sorted(),
            hasSheet: window?.attachedSheet != nil, topPage: controller.shownTopPage != nil
        )
    }

    static func keyWindow(_ controllers: [WindowController]) -> InputObservation.KeyWindow {
        guard let key = NSApp.keyWindow else { return .none }
        if let controller = controllers.first(where: { $0.window === key }) { return .window(controller.state.id) }
        let kind = String(describing: type(of: key))
        if let parent = key.sheetParent, let controller = controllers.first(where: { $0.window === parent }) {
            return .sheet(window: controller.state.id)
        }
        let owner = key.parent.flatMap { parent in controllers.first { $0.window === parent } }
        if key is NSPanel { return .panel(window: owner?.state.id, kind: kind) }
        if let owner { return .childPage(window: owner.state.id) }
        return .other(kind)
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
/// The oracle's `focus` facet (schemas/oracle/snapshot-v1.schema.json `focus`): the same
/// `observe` the input monitor checks, so the facet and the W invariants see one state and there is no
/// second reader of AppKit or Ghostty focus. Chromium's interactive UI tests read focus the same way, from
/// the FocusManager that owns it (ui/views/focus/focus_manager.h, `GetFocusedView`), never a test-side tracker.
extension InputObservationBuilder {
    static func oracleFocusFacet(_ services: AppServices) -> OracleFacetSource {
        OracleFacetSource(.focus, .mainActor { [weak services] () throws(OracleFacetError) -> OracleValue in
            guard let services else { throw OracleFacetError("the app services are gone") }
            return oracleFocus(observe(services))
        })
    }

    /// `observation` in the schema's form: public window ids (`win_<hex>`, as `snapshot.get` prints them), the
    /// model's target and resolved kind as `debug.focus` names them, and per window whether no world
    /// invariant violation names it. Settle state is not folded in: `debug.oracle.settle` and I5 own it.
    static func oracleFocus(_ observation: InputObservation) -> OracleValue {
        let broken = Set(InputInvariants.world(observation).violations.compactMap(\.window))
        func id(_ key: String?) -> OracleValue { key.map { .string(ControlWindowInfo.publicID(forKey: $0)) } ?? .null }
        func string(_ value: String?) -> OracleValue { value.map(OracleValue.string) ?? .null }
        let windows = observation.windows.map { window -> OracleValue in
            let model = window.model
            return [
                "id": id(window.id),
                "isKey": .bool(window.isKey),
                "responder": .string(String(FocusResponderClassifier.describe(window.responder).prefix { $0 != ":" })),
                "responderPane": string(window.responder.pane),
                "layoutFocus": string(window.layoutFocus),
                "ghosttyFocused": .array(window.ghosttyFocused.map(OracleValue.string)),
                "childPage": string(window.childPage),
                "hasSheet": .bool(window.hasSheet),
                "topPage": .bool(window.topPage == true),
                "model": [
                    "pane": string(model.pane),
                    "target": .string(String(describing: model.target)),
                    "resolved": .string(model.resolved.kind),
                    "resolvedPane": string(model.resolved.pane),
                    "resolvedTab": string(model.resolved.tab),
                    "overlays": .array(model.overlays.map { .string($0.rawValue) }),
                    "dragging": .bool(model.isDragging),
                    "windowKey": .bool(model.windowKey),
                    "sidebarHidden": .bool(model.sidebarHidden),
                    "generation": .number(Double(model.generation)),
                ],
                "consistent": .bool(!broken.contains(window.id)),
            ]
        }
        let keyWindow: (kind: String, window: String?) = switch observation.keyWindow {
        case .none: ("none", nil)
        case .window(let window): ("window", window)
        case .childPage(let window): ("childPage", window)
        case .panel(let window, _): ("panel", window)
        case .sheet(let window): ("sheet", window)
        case .other: ("other", nil)
        }
        let context = observation.context
        return [
            "windows": .array(windows),
            "keyWindow": ["kind": .string(keyWindow.kind), "window": id(keyWindow.window)],
            "activeWindow": id(observation.activeWindow),
            "paletteOpen": .bool(observation.paletteOpen),
            "context": ["terminal": .bool(context.terminal), "browser": .bool(context.browser), "agent": .bool(context.agent)],
        ]
    }
}
#endif
