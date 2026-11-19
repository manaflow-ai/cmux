import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextWakeups

// Page shortcuts (``PageShortcutRoute``, CMUX-641): a focused Chromium page gets a shortcut it shares with cmux first,
// and cmux runs it only when the page leaves it unhandled. cmux mode (Cmd-Opt-Return) gives the keys back to cmux.
extension KeyRouter {
    /// The cmux action held for a key a page has first (``PageFirstKeyOffer``), with its context and window.
    typealias HeldPageKey = (candidate: Candidate, context: KeyContext, window: String)

    /// The toast kind of the one-time cmux mode notice: Don't Show Again hides it for good.
    static let cmuxModeNoticeID = "browser.cmuxModeNotice"

    /// `candidate`'s route while a page has the keyboard in `focus`; nil for a key that never goes to a page first:
    /// not a registry shortcut, a DevTools key, or a native palette key (Cmd-Shift-P, Cmd-P).
    nonisolated static func pageRoute(_ candidate: Candidate, focus: FocusState) -> PageShortcutRoute? {
        guard case .browserPage = focus.resolved, case .registry = candidate.source,
              !devToolsActions.contains(candidate.id), !nativePaletteActions.contains(candidate.id) else { return nil }
        return PageShortcutRoute(id: candidate.id, tier: candidate.tier)
    }

    /// Whether `candidate` waits for the page instead of running first (``PageShortcutRoute/offersToPage(pageHasKeys:cmuxMode:)``).
    /// `chromium` stands in for the page's report when the page window does not have the keyboard yet.
    nonisolated static func offersToPage(_ candidate: Candidate, event: NSEvent, focus: FocusState, facts: Facts, chromium: Bool? = nil) -> Bool {
        pageRoute(candidate, focus: focus)?.offersToPage(pageHasKeys: chromium ?? facts.pageReportsUnhandledKeys,
                                                        cmuxMode: focus.isBrowserFocusModeActive) ?? false
    }

    /// The browser tab `controller`'s focused pane shows while a page has the keyboard.
    func focusedBrowserTab(in controller: WindowController) -> (any BrowserTab)? {
        guard case .browserPage = controller.focus.state.resolved, let pane = controller.focus.state.resolved.pane,
              case .browser(let entry)? = controller.content?.paneController(key: pane)?.currentContent else { return nil }
        return entry.tab
    }

    /// Holds `candidate` until the page of `tab` reports `event` unhandled. An app shortcut the page keeps shows the
    /// cmux mode notice once (``showsCmuxModeNotice(for:route:tab:in:)``).
    func offerToPage(_ event: NSEvent, candidate: Candidate, context: KeyContext, window: String, tab: ObjectIdentifier) {
        pageFirstOffer.offer(event, (candidate: candidate, context: context, window: window), tab: tab)
        trace?("dispatcher: the page gets the key first; \(candidate.id.rawValue) runs if it is left unhandled")
        if PageShortcutRoute(id: candidate.id, tier: candidate.tier).isAppShortcut { noticeIfPageKeeps(event, window: window) }
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

    /// A key `decide` runs now because the Chromium page window does not have the keyboard yet (a relaunch, a tab bar
    /// click: the first Cmd-K ran Search Chats, Lucas 2026-11-18), though the page would get it first: sends it to the
    /// page window, which reports it unhandled as usual. Returns whether it took the key.
    func givesPageFirst(_ event: NSEvent, candidate: Candidate, context: KeyContext, focus: FocusState, facts: Facts,
                        controller: WindowController) -> Bool {
        guard !facts.pageReportsUnhandledKeys, let tab = focusedBrowserTab(in: controller) as? CEFTab, let page = tab.pageWindow,
              Self.offersToPage(candidate, event: event, focus: focus, facts: facts, chromium: true) else { return false }
        offerToPage(event, candidate: candidate, context: context, window: controller.state.id, tab: ObjectIdentifier(tab))
        // main-hop-allow: the held key goes to its page window after the turn that held it
        Task { @MainActor [weak self] in
            // The person moved to another tab during the hop: the key is not that tab's.
            guard let self, focusedBrowserTab(in: controller) === tab else { return }
            FocusRoute(.person, "a page shortcut sent to its page window").makeKey(page)
            page.sendEvent(event)
        }
        return true
    }

    /// Shows the cmux mode notice when the page keeps `event`, an app shortcut: no unhandled report came back in
    /// ``cmuxModeNoticeWait`` (Chromium reports only the keys a page leaves unhandled). Once a launch, until the person
    /// picks Don't Show Again.
    private func noticeIfPageKeeps(_ event: NSEvent, window: String) {
        guard !cmuxModeNoticeShown, !undoToasts.neverShow.isHidden(Self.cmuxModeNoticeID),
              let toggle = registry.shortcutDisplay(for: "toggleBrowserFocusMode") else { return }
        let notice = BrowserCmuxModeNotice(key: ShortcutRecorder.shortcut(for: event).displayString, toggle: toggle)
        let held = PageFirstKeyOffer<HeldPageKey>.Signature(event)
        cmuxModeNoticeTimer.schedule(after: Self.cmuxModeNoticeWait) { @MainActor [weak self] in
            guard let self, !cmuxModeNoticeShown, pageFirstOffer.holds(held),
                  let shell = services?.windows.controllers.first(where: { $0.state.id == window })?.window else { return }
            cmuxModeNoticeShown = true
            undoToasts.show(CmuxToast(id: Self.cmuxModeNoticeID, message: notice.message), in: shell)
        }
    }

    /// How long a page has to report a key unhandled before the notice reads it as kept: Chromium answers in a
    /// frame or two.
    static var cmuxModeNoticeWait: Duration { .milliseconds(300) }
}
