import AppKit

extension KeyRouter {
    /// Starts capturing at the action, while the previous tab may still be first responder.
    func beginNewTabInput(for pane: PaneController) -> String? {
        guard let window = pane.view.window else { return nil }
        // One opening owns a window's pre-first-responder queue. Serialize a
        // second Cmd-T in another pane until the first opening settles rather
        // than allowing the queues to overwrite each other.
        guard newTabInput[window.windowNumber] == nil else { return nil }
        let buffer = NewTabInputBuffer(focusField: { [weak pane, weak window] in
            guard let pane, let window, let key = pane.currentTabKey,
                  pane.services.agentTabs.isNewTabPage(key),
                  let view = pane.services.agentTabs.existingView(key), view.window === window else { return false }
            return window.makeFirstResponder(view.webView)
        }, deliver: { [weak self, weak window] event in
            guard let self, let window else { return }
            self.dispatchingSynthetic(event) {
                if !self.interceptKeyDown(event, in: window) { window.sendEvent(event) }
            }
        })
        newTabInput[window.windowNumber] = buffer
        return buffer.token
    }

    func cancelNewTabInput(in window: NSWindow?) {
        guard let window else { return }
        newTabInput[window.windowNumber] = nil
    }

    func captureNewTabInput(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, !Self.isChord(event.modifierFlags),
              (Self.isPrintable(event) || event.keyCode == Self.deleteKeyCode) else { return false }
        let (controller, kind) = focus(for: window)
        guard kind == .content, controller != nil else { return false }
        return newTabInput[window.windowNumber]?.capture(event) ?? false
    }

    func acknowledgeNewTabInput(_ token: String, in window: NSWindow?) {
        guard let window else { return }
        newTabInput[window.windowNumber]?.acknowledge(token)
        flushNewTabInput(in: window)
    }

    func flushNewTabInput(in window: NSWindow?) {
        guard let window, let buffer = newTabInput[window.windowNumber], buffer.drain() else { return }
        // A replayed Cmd-T can create the next opening; it keeps its own queue.
        if newTabInput[window.windowNumber] === buffer { newTabInput[window.windowNumber] = nil }
    }
}
