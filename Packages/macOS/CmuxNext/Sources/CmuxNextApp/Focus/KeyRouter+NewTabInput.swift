import AppKit

/// Owns the short interval between Cmd-T and the New Tab field's readiness acknowledgement.
@MainActor
final class NewTabInputCoordinator {
    weak var router: KeyRouter?
    private var buffers: [Int: NewTabInputBuffer] = [:]

    init(router: KeyRouter) { self.router = router }

    func begin(for pane: PaneController) -> String? {
        guard let router, let window = pane.view.window, buffers[window.windowNumber] == nil else { return nil }
        let buffer = NewTabInputBuffer(focusField: { [weak pane, weak window] in
            guard let pane, let window, let key = pane.currentTabKey,
                  pane.services.agentTabs.isNewTabPage(key),
                  let view = pane.services.agentTabs.existingView(key), view.window === window else { return false }
            return window.makeFirstResponder(view.webView)
        }, deliver: { [weak router, weak window] event in
            guard let router, let window else { return }
            router.dispatchingSynthetic(event) {
                if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
            }
        })
        buffers[window.windowNumber] = buffer
        return buffer.token
    }

    func cancel(in window: NSWindow?) {
        guard let window else { return }
        buffers[window.windowNumber] = nil
    }

    func capture(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let router, let window, !KeyRouter.isChord(event.modifierFlags),
              (KeyRouter.isPrintable(event) || event.keyCode == KeyRouter.deleteKeyCode) else { return false }
        let (controller, kind) = router.focus(for: window)
        guard kind == .content, controller != nil else { return false }
        return buffers[window.windowNumber]?.capture(event) ?? false
    }

    func acknowledge(_ token: String, in window: NSWindow?) {
        guard let window else { return }
        buffers[window.windowNumber]?.acknowledge(token)
        flush(in: window)
    }

    func flush(in window: NSWindow?) {
        guard let window, let buffer = buffers[window.windowNumber], buffer.drain() else { return }
        if buffers[window.windowNumber] === buffer { buffers[window.windowNumber] = nil }
    }
}
