import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTabs

extension AppActions {
    static func bindBrowser(_ services: AppServices) {
        let registry = services.registry
        func chrome(_ invocation: ActionInvocation = ActionInvocation()) -> BrowserChromeView? {
            if case .browser(let entry) = scope(services, invocation).pane?.currentContent { return entry.chrome }  // shown: bound
            return nil
        }
        let commands: [(String, BrowserChromeCommand)] = [
            ("browserBack", .goBack), ("browserForward", .goForward), ("browserReload", .reload), ("browserStop", .stop),
            ("browserZoomIn", .zoomIn), ("browserZoomOut", .zoomOut), ("browserZoomReset", .resetZoom),
            ("focusBrowserAddressBar", .focusAddressBar),
        ]
        for (id, command) in commands where command != .focusAddressBar {
            registry.bind(ActionID(rawValue: id), isEnabled: { chrome() != nil }, invoke: { invocation in
                guard let browser = chrome(invocation) else { return }
                browser.perform(command)
                if command == .zoomIn || command == .zoomOut || command == .resetZoom {
                    SurfaceZoomIndicator.show(percent: Int((browser.tab.state.zoom * 100).rounded()),
                                              in: services.windows.active?.window)
                }
            })
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
        // A page of the Back or Forward menu, by its goToEntry offset (-2, 1).
        let listing = { (invocation: ActionInvocation) in chrome(invocation)?.tab as? any BrowserBackForwardListing }
        let previous = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.browserBackForwardEntries else { return previous?(source) ?? [] }
            guard let list = listing(ActionInvocation())?.navigationList() else { return [] }
            return (list.back + list.forward).map { ActionEnumCase(value: String($0.offset), title: $0.entry.rowTitle) }
        }
        registry.bindEffect("browser.goToHistoryEntry", requires: nil, effect: { invocation in
            let offset = invocation["entry"]?.stringValue.flatMap { Int($0) } ?? invocation["entry"]?.intValue ?? 0
            guard offset != 0, let tab = listing(invocation), tab.goToEntry(offset: offset) else {
                throw ActionFailure(message: RefusalStrings.noHistoryEntry)
            }
            return .done
        })
        // A machine browser tab that is not ready: this Mac's page in its place (cx-2cob).
        registry.bind("browser.openLocally", isEnabled: { chrome()?.tab is MachineBrowserPageTab },
                      invoke: { (chrome($0)?.tab as? MachineBrowserPageTab)?.openLocally() })
        // This Mac's tab in a machine's workspace: its page on the machine (the This Mac chip's menu).
        registry.bind("browser.openOnMachine", isEnabled: {
            guard let chrome = chrome(), !(chrome.tab is MachineBrowserPageTab), let key = chrome.addressBar.tabKey else { return false }
            return services.daemon(ofBrowserTab: key)?.isLocal == false
        }, invoke: { invocation in
            guard let key = chrome(invocation)?.addressBar.tabKey else { return }
            _ = services.openTabOnMachine(key: key)
        })
        // Site settings of the site that blocked the newest download (the
        // blocked-download notice's button, without the mouse).
        registry.bind("browser.download.openBlockedSiteSettings", isEnabled: { services.cache.pageRequests.canOpenLatestBlockedSiteSettings },
                      invoke: { _ in
                          let requests = services.cache.pageRequests
                          if let latest = requests.downloads.latestBlocked { requests.openBlockedSiteSettings(site: latest.site, tab: latest.tab) }
                      })
        // The prompt bar's permission question, answered without the mouse.
        let promptAnswers: [(ActionID, BrowserPrompt.PermissionChoice)] = [("browser.prompt.allow", .allow), ("browser.prompt.block", .block)]
        for (id, choice) in promptAnswers {
            registry.bind(id, isEnabled: { chrome().flatMap { BrowserPrompt.firstPermission(in: $0.tab.pendingPrompts) } != nil },
                          invoke: { _ = chrome($0).map { BrowserPrompt.answerFirstPermission(choice, in: $0.tab.pendingPrompts) } })
        }
        // Cmd-L goes through the window's focus coordinator, which also takes key back from a focused Chromium page window.
        // Opt-Cmd-F (Chrome's Search the Web, `search`): the address bar as Cmd-L focuses it, then a default-engine search.
        let addressBarFocuses: [(ActionID, search: Bool)] = [("focusBrowserAddressBar", false), ("browser.focusSearch", true)]
        for (id, search) in addressBarFocuses {
            registry.bind(id, isEnabled: { chrome() != nil }, invoke: { invocation in
                guard let pane = scope(services, invocation).pane, case .browser(let entry) = pane.currentContent,
                      let window = services.windowController(showing: pane) else { return }
                let bar = entry.chrome?.addressBar
                // Chromium `OmniboxViewViews::SetFocus(is_user_initiated=true)`: Cmd-L in a focused omnibar shows the full URL and
                // selects all again. The responder stays; focusing the pane first would hand focus to the page and back.
                if bar?.isEditing != true {
                    window.focus.send(.focusPane(pane.paneKey, source: .intent))
                    window.focus.send(.focusTarget(.addressBar, source: .intent))
                } else if !search { bar?.focus() }
                if search { bar?.beginSearch() }
            })
        }
    }
}
