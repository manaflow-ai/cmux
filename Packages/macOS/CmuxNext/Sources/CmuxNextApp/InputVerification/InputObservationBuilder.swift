import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextFocus
import CmuxNextInputModel

/// Reads the live combined input state into an `InputObservation`: each
/// window's focus model next to AppKit's first responder and key window,
/// Ghostty's focused surfaces, the layout focus and Chromium page focus.
/// Main actor, read-only, cheap (no layout, no IO).
enum InputObservationBuilder {
    /// - Parameter reuse: A window's observation from before that is still current (nothing it reads changed since):
    ///   taken as is instead of walking the window's panes again (the invariant pass rebuilds only the windows a
    ///   turn touched, the key window and the active one). The default rebuilds every window.
    static func observe(_ services: AppServices,
                        reuse: (WindowController) -> InputObservation.Window? = { _ in nil }) -> InputObservation {
        let ghostty = Set(services.cache.focusedTerminalTabs)
        let owed = services.cache.pendingBrowsers
        let controllers = services.windows.controllers
        let context = services.registry.context
        return InputObservation(
            windows: controllers.map { reuse($0) ?? window(of: $0, ghostty: ghostty, owed: owed) },
            keyWindow: keyWindow(controllers),
            paletteOpen: context.contains(.paletteOpen),
            activeWindow: services.windows.active?.state.id,
            context: FocusState.Context(terminal: context.contains(.terminalFocused), browser: context.contains(.browserFocused),
                                     agent: context.contains(.agentPaneFocused)),
            appActive: NSApp.isActive
        )
    }

    static func window(of controller: WindowController, ghostty: Set<String>, owed: Set<String> = []) -> InputObservation.Window {
        let window = controller.window
        var presented: [String: String] = [:]
        var owedPanes: [String] = []
        var childWindowTabs: [String] = []
        // A cmux page's Chromium tab has its own id; the model knows the page by its tab key.
        var pageTabKeys: [String: String] = [:]
        for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
            guard let key = pane.currentTabKey else { continue }
            presented[pane.paneKey] = key
            let chromium = pane.currentContent?.chromiumTab as? CEFTab
            // Owed: the page is made after the frame commits or waits for its engine, or its Chromium browser does
            // not exist yet (`CEFPaneHost.createAfterCommit`): nothing in the pane can have the keys yet.
            if owed.contains(key) || chromium.map({ $0.browserID == nil }) == true { owedPanes.append(pane.paneKey) }
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
            hasSheet: window?.attachedSheet != nil, topPage: controller.shownTopPage != nil,
            visible: window?.isVisible ?? false, owed: owedPanes.isEmpty ? nil : owedPanes.sorted()
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
