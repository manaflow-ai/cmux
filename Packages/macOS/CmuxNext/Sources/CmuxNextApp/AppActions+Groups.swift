import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTabs

extension AppActions {
    static func bindBrowser(_ services: AppServices) {
        let registry = services.registry
        func chrome(_ invocation: ActionInvocation = ActionInvocation()) -> BrowserChromeView? {
            if case .browser(let entry) = scope(services, invocation).pane?.currentContent { return entry.chrome }
            return nil
        }
        let commands: [(String, BrowserChromeCommand)] = [
            ("browserBack", .goBack), ("browserForward", .goForward), ("browserReload", .reload), ("browserStop", .stop),
            ("browserZoomIn", .zoomIn), ("browserZoomOut", .zoomOut), ("browserZoomReset", .resetZoom),
            ("focusBrowserAddressBar", .focusAddressBar),
        ]
        for (id, command) in commands where command != .focusAddressBar {
            registry.bind(ActionID(rawValue: id), isEnabled: { chrome() != nil }, invoke: { chrome($0)?.perform(command) })
        }
        // Cmd-Return / Shift-Cmd-Return in the address bar: the typed URL or
        // search opens in a new tab (Chrome, Safari) through the tab's
        // `onOpenURL` (`BrowserPageRequests.openFromOmnibar`).
        let omnibarOpens: [(ActionID, OmnibarDisposition)] = [
            ("omnibar.openInBackgroundTab", .newBackgroundTab), ("omnibar.openInForegroundTab", .newForegroundTab),
        ]
        for (id, disposition) in omnibarOpens {
            registry.bind(id, isEnabled: { chrome()?.addressBar.isEditing == true }, invoke: { chrome($0)?.addressBar.commit(disposition) })
        }
        // Shift-Cmd-G in a browser: the same Find Previous as Cmd-Opt-G.
        registry.bind("browser.findPrevious", isEnabled: { chrome() != nil }, invoke: { invocation in
            registry.perform("findPrevious", invocation: invocation)
        })
        // Cmd-Shift-C (Arc, Chrome extensions): the page's URL, as the
        // omnibar's Copy writes it (the full URL, never the elided text).
        registry.bind("browser.copyURL", isEnabled: { chrome()?.tab.state.url != nil }, invoke: { _ = chrome($0)?.copyPageURL() })
        // Cmd-L goes through the window's focus coordinator, which also takes
        // key back from a focused Chromium page window.
        registry.bind("focusBrowserAddressBar", isEnabled: { chrome() != nil }, invoke: { invocation in
            guard let pane = scope(services, invocation).pane, case .browser(let entry) = pane.currentContent,
                  let window = services.windowController(showing: pane) else { return }
            // Chromium `OmniboxViewViews::SetFocus(is_user_initiated=true)`:
            // Cmd-L while the omnibar already has focus shows the full URL
            // and selects all again. The responder stays; focusing the pane
            // first would hand focus to the page and back.
            if entry.chrome.addressBar.isEditing {
                entry.chrome.addressBar.focus()
                return
            }
            window.focus.send(.focusPane(pane.paneKey, source: .intent))
            window.focus.send(.focusTarget(.addressBar, source: .intent))
        })
    }
}
