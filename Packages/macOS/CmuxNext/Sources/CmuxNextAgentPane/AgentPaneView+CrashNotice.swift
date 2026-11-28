import AppKit
import CmuxNextDesign
import CmuxNextPages

/// A page whose web content process ended loads again by itself in a new process
/// (``AgentPageCrashRetry``): at once when the pane is on screen, else when it is next shown, with
/// no notice meanwhile (Leo, 2026-11-01: "how come it says this??? why doens't it just retry on its
/// own"). A page that keeps ending (3 retries in 60 s) shows the crash notice, a line with no
/// button, and still loads again by itself every 30 s while shown (Leo, 2026-11-22: "vacuous
/// decisions like that should be just done"). The process already took what the page held (an
/// open menu, the caret, unsent chips), so a retry loses nothing a Reload would keep.
extension AgentPaneView {
    /// The old host's web content process ended (`termination`: WebKit's reason and pid, or an
    /// injected end in tests): logged with its siblings (``AgentPageTerminations``), then a retry
    /// or the notice.
    func webContentProcessDidTerminate(_ termination: PageTermination = .unknown) {
        // The old host has no page to tell it: its last frame stays until a new document paints.
        documentWillChange(.contentEnded)
        contentEnded(termination.withPid(fallback: knownWebContentPid))
    }

    /// The page host's crash report: the same as ``webContentProcessDidTerminate(_:)``, with the
    /// reload policy kept by the page host.
    func pageCrashed(reloading: Bool) {
        model.sessionInfo.pageLoaded()
        model.hostGlass.pageLoaded()
        guard !reloading else {
            dictation.handle(.cancel)
            return
        }
        contentEnded(page?.lastTermination ?? .unknown)
    }

    private func contentEnded(_ termination: PageTermination) {
        model.sessionInfo.pageLoaded()
        model.setToastAvoidance(nil)
        model.hostGlass.pageLoaded()
        // The composer that held the session's words is gone.
        dictation.handle(.cancel)
        let retries = crashRetry.ended(self)
        terminations.ended(self, termination: termination, retries: retries)
        if !retries { showCrashNotice() }
    }

    /// Loads the page again in a new process (an automatic retry): WebKit starts a new web
    /// content process for the load, Chromium a new renderer.
    func retryAfterCrash() {
        if let page { page.reloadAfterCrashes() } else { source.load(into: webView) }
    }

    private func showCrashNotice() {
        guard crashNotice == nil else { return }
        // It kept ending: the notice says so, over the page, not over a picture of a chat that works.
        endDocumentCover(painted: false, reason: "crash notice")
        let message = ChromeLabel(wrappingLabelWithString: Self.crashedMessage)
        message.alignment = .center
        let notice = NSStackView(views: [message])
        notice.orientation = .vertical
        notice.spacing = 12
        notice.translatesAutoresizingMaskIntoConstraints = false
        addSubview(notice)
        let inset = notice.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48)
        // A pane narrower than the inset clips the notice instead of
        // breaking the layout.
        inset.priority = .defaultHigh
        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: centerXAnchor),
            notice.centerYAnchor.constraint(equalTo: centerYAnchor),
            inset,
        ])
        crashNotice = notice
        themeCrashNotice(themeTokens)
    }

    /// The notice sits on the pane's background, so it takes the pane's
    /// theme rather than the system appearance.
    func themeCrashNotice(_ tokens: ThemeTokens) {
        guard let notice = crashNotice else { return }
        notice.appearance = NSAppearance(named: tokens.isDark ? .darkAqua : .aqua)
        for case let label as ChromeLabel in notice.subviews {
            label.textColor = tokens.textSecondary.nsColor
        }
    }

    /// The page finished loading a document after its end: it lives, so the notice goes and the
    /// chat leaves its crash group (a sibling's Reload must not reload it). The notice showed over a
    /// working chat before this (user report 2026-10-30): a host route, a retarget or a WebKit
    /// fallback had loaded the page again, and only Reload took the notice away.
    func pageLoadedAgain() {
        // A document loaded while the chat waits drawn away starts "visible": tell it it is hidden.
        page?.reapplyDrawnAway()
        // Every host's load lands here: a start's card is gone with the old document, so its question moves to a dialog.
        model.cloudAsks.pageReloaded()
        // A page that came back before its owed retry ran needs none.
        crashRetry.cancel()
        guard let notice = crashNotice else { return }
        notice.removeFromSuperview()
        crashNotice = nil
        terminations.loadedAgain(self, session: model.sessionId)
    }

    /// Reloads now every chat that ended with this one (`debug.agent_pane` crash_notice press).
    func reloadAfterCrashes() {
        terminations.reload(from: self)
    }

    /// Takes the notice away and reloads this pane's page (a reload of every chat that ended with
    /// this one, ``reloadAfterCrashes()``).
    func reloadAfterCrash() {
        crashNotice?.removeFromSuperview()
        crashNotice = nil
        crashReloadCount += 1
        // A reload that starts over: the next end retries quickly again.
        crashRetry.cancel()
        crashRetry.budget.reset()
        if let page { page.reloadAfterCrashes() } else { source.load(into: webView) }
    }
}

extension AgentPaneView {
    /// The person's reload (Cmd-R, "Agent Chat: Reload", the tab's Reload): a crash notice's Reload when one
    /// shows, else the page saves its draft and reloads under a picture of itself (``PageWebView/reloadForPerson(saveWait:)``),
    /// so the chat never blanks. The old host (no page host) loads its document again.
    /// A crash notice's Reload brings back every chat that ended with this one, as the notice's button does.
    /// Repeated requests while the page saves are one reload, and the pane's close cancels it (``close()``).
    public func reloadForPerson() {
        if crashNotice != nil { return reloadAfterCrashes() }
        guard let page else { return source.load(into: webView) }
        guard personReload == nil else { return }
        // task-owner: personReload; one save-then-reload, cancelled by close(), cleared when it ends
        personReload = Task { [weak self, page] in
            await page.reloadForPerson()
            self?.personReload = nil
        }
    }
}
