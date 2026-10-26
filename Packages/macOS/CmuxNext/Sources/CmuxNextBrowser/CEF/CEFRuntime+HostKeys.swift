import AppKit

extension CEFRuntime {
    /// Chromium Host: the page left the chord with key seq `seq` unhandled (KEY_UNHANDLED; the
    /// host has no key_fn and never asks cmux before the page, p01-process-030). The action the
    /// KeyRouter held for the page runs, else the key goes to cmux's menus: Chrome's unhandled-key
    /// path (`ui/base/cocoa/command_dispatcher.mm`, `-redispatchKeyEvent:`). A seq the page view no
    /// longer holds (its pane closed, or the report came twice) does nothing.
    func redispatchUnhandledKey(seq: Int32, browser: Int32) {
        guard let page = tabsByBrowser[browser]?.host.hostedPageView, let event = page.takeUnhandledKey(seq: seq) else { return }
        if routeUnhandledKey(event, browser: browser) { return }
        page.redispatch(event)
    }
}
