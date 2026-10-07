import AppKit
import CmuxNextActions
import CmuxNextBrowser

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
        for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
            guard let key = pane.currentTabKey else { continue }
            presented[pane.paneKey] = key
            if case .browser(let entry)? = pane.currentContent, entry.tab.presentation == .childWindow { childWindowTabs.append(key) }
        }
        return InputObservation.Window(
            id: controller.state.id,
            model: controller.focus.state,
            responder: FocusResponderClassifier.classify(window?.firstResponder, in: controller),
            responderClass: window?.firstResponder.map { String(describing: type(of: $0)) },
            isKey: window?.isKeyWindow ?? false,
            layoutFocus: controller.content?.layoutModel.focusedPane?.rawValue,
            ghosttyFocused: presented.values.filter(ghostty.contains).sorted(),
            childPage: controller.focusApplier.focusedChildWindowPageID,
            presented: presented,
            childWindowTabs: childWindowTabs.sorted(),
            hasSheet: window?.attachedSheet != nil
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
