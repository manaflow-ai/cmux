import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextSettings
import os

// `browser.pageShortcuts` (``PageShortcutRoute``): who gets a shortcut that cmux and a Chromium page both use.
extension KeyRouter {
    /// The cmux action held for a key a page has first (``PageFirstKeyOffer``), with its context and window.
    typealias HeldPageKey = (candidate: Candidate, context: KeyContext, window: String)

    /// `candidate`'s route while a page has the keyboard in `focus` and focus mode is off; nil for a key that never goes
    /// to a page first: not a registry shortcut, a DevTools key, or a native palette key (Cmd-Shift-P, Cmd-P).
    nonisolated static func pageRoute(_ candidate: Candidate, focus: FocusState) -> PageShortcutRoute? {
        guard case .browserPage = focus.resolved, !focus.isBrowserFocusModeActive, case .registry = candidate.source,
              !devToolsActions.contains(candidate.id), !nativePaletteActions.contains(candidate.id) else { return nil }
        return PageShortcutRoute(id: candidate.id, tier: candidate.tier)
    }

    /// Whether `candidate` waits for the page instead of running first (``PageShortcutRoute/offersToPage(pageHasKeys:pageFirst:)``).
    nonisolated static func offersToPage(_ candidate: Candidate, event: NSEvent, focus: FocusState, facts: Facts) -> Bool {
        pageRoute(candidate, focus: focus)?.offersToPage(pageHasKeys: facts.pageReportsUnhandledKeys, pageFirst: facts.pageFirstShortcuts) ?? false
    }

    /// The browser tab `controller`'s focused pane shows while a page has the keyboard.
    func focusedBrowserTab(in controller: WindowController) -> (any BrowserTab)? {
        guard case .browserPage = controller.focus.state.resolved, let pane = controller.focus.state.resolved.pane,
              case .browser(let entry)? = controller.content?.paneController(key: pane)?.currentContent else { return nil }
        return entry.tab
    }

    /// Holds `candidate` until the page of `tab` reports `event` unhandled.
    func offerToPage(_ event: NSEvent, candidate: Candidate, context: KeyContext, window: String, tab: ObjectIdentifier) {
        pageFirstOffer.offer(event, (candidate: candidate, context: context, window: window), tab: tab)
        trace?("dispatcher: the page gets the key first; \(candidate.id.rawValue) runs if it is left unhandled")
    }

    /// The page of `tab` did not handle `event`: runs the action held for it. Returns whether one ran.
    /// Runs nothing when another tab took the keyboard before the report (a late Reload never acts on it).
    func runUnhandledPageKey(_ event: NSEvent, from tab: ObjectIdentifier) -> Bool {
        guard let held = pageFirstOffer.take(event, from: tab) else { return false }
        if let controller = services?.windows.controllers.first(where: { $0.state.id == held.window }),
           focusedBrowserTab(in: controller).map { ObjectIdentifier($0) } != tab {
            trace?("dispatcher: \(held.candidate.id.rawValue) dropped: its page lost the keyboard before it answered")
            return true
        }
        run(held.candidate, context: held.context, window: held.window)
        return true
    }

    /// Whether `ask` asks about `candidate` (``PageShortcutRoute/asks(pageHasKeys:)``). `chromium`: a Chromium page, its
    /// window keyed or not yet (a relaunch, a tab bar click: the first Cmd-K ran Search Chats, Lucas 2026-11-18).
    nonisolated static func asksAboutPageShortcut(_ candidate: Candidate, event: NSEvent, focus: FocusState, facts: Facts, chromium: Bool? = nil) -> Bool {
        pageRoute(candidate, focus: focus)?.asks(pageHasKeys: chromium ?? facts.pageReportsUnhandledKeys) ?? false
    }

    /// The page's site answers `ask` (not asked this launch, not incognito: nothing of it is saved), a key it asks about:
    /// holds `event` and asks; the answer is saved for the site, or every site. A site answering `page` whose page window
    /// does not have the keyboard yet (a relaunch, a tab bar click) gets the key too. Returns whether it took the key.
    func asksPageShortcuts(_ event: NSEvent, candidate: Candidate, context: KeyContext, focus: FocusState, facts: Facts,
                           controller: WindowController) -> Bool {
        guard let settings = services?.settings, let tab = focusedBrowserTab(in: controller), let window = controller.window,
              case .browserPage(_, let tabID) = controller.focus.state.resolved, let host = tab.state.url?.host(), Self.asksAboutPageShortcut(candidate, event: event, focus: focus, facts: facts, chromium: tab is CEFTab)
        else { return false }
        let windowID = controller.state.id
        switch settings.snapshot.pageShortcuts(forHost: host) {
        case .page where !facts.pageReportsUnhandledKeys: givePage(event, candidate, context, window: windowID, tab: tab, in: window); return true
        case .ask where !askedPageShortcutSites.contains(host) && services?.cache.browserTabs.isIncognitoTab(tabID) == false: break
        default: return false
        }
        askedPageShortcutSites.insert(host)
        let prompt = BrowserPageShortcutsPrompt(key: ShortcutRecorder.shortcut(for: event).displayString, host: host,
                                                focusMode: registry.shortcutDisplay(for: "toggleBrowserFocusMode"))
        CmuxDialogCenter.shared.present(prompt.spec, in: .window(window)) { [weak self] answer in
            guard let self, let mode = prompt.mode(for: answer) else { return }
            askedPageShortcutSites.remove(host)  // answered: a site rule removed later asks again
            let sites = settings.snapshot.browserPageShortcutSites.setting(BrowserPageShortcuts(rawValue: mode) ?? .cmux, forHost: host)
            let (path, value) = prompt.appliesToAllSites(answer) ? (BrowserPageShortcutsSetting.configPath, JSONValue.string(mode)) : (BrowserPageShortcutSites.pageShortcutSitesPath, sites)
            // main-hop-allow: one settings write a dialog button started; setSetting hands it to the config owner, off main
            Task { @MainActor in
                do { try await settings.setSetting(at: path, to: value, by: .user) } catch {
                    Logger(subsystem: "com.cmuxterm.app.next", category: "keys").error("browser.pageShortcuts write failed: \(String(describing: error), privacy: .public)")
                }
            }
            guard mode == BrowserPageShortcutsPrompt.pageFirst else { return run(candidate, context: context, window: windowID) }
            // The page went to another site while the dialog showed: the held key is not that site's.
            if tab.state.url?.host() == host { givePage(event, candidate, context, window: windowID, tab: tab, in: window) }
        }
        return true
    }

    /// Sends `event` to `tab`'s page window as `page` does: `candidate` runs if the page leaves it unhandled.
    private func givePage(_ event: NSEvent, _ candidate: Candidate, _ context: KeyContext, window: String, tab: any BrowserTab, in shell: NSWindow) {
        offerToPage(event, candidate: candidate, context: context, window: window, tab: ObjectIdentifier(tab))
        let page = (tab as? CEFTab)?.pageWindow ?? shell  // main-hop-allow: the held key goes to its page window after the turn that held it
        Task { @MainActor in FocusRoute(.person, "the page shortcut the person chose for the page").makeKey(page); page.sendEvent(event) }
    }
}
