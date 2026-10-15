import CmuxBrowser
import Foundation

/// Crash and hang recovery for a non-WebKit (Chromium) page (design spec §8).
///
/// The renderer's end shows Chrome's "Aw, Snap!" page with Reload; a pane
/// that was visible when its renderer ended waits for that Reload, so a page
/// that crashes its renderer cannot reload itself in a loop. A pane that was
/// hidden restores its page when shown (at most 3 times in 10 minutes). A hung
/// renderer gets the "Page unresponsive" card: Wait restarts Chromium's hang
/// timer, Exit page ends the renderer. The rest of cmux keeps running either
/// way; the crash is recorded in `debug.browser.crashes`. WebKit panels keep
/// their own recovery (`BrowserPanel+WebContentTermination.swift`).
extension BrowserPanel {
    /// Feeds a page event to the crash and hang state.
    func noteEnginePageSafetyEvent(_ event: BrowserPageEvent, now: Date = Date()) {
        switch event {
        case .processTerminated(let exit):
            BrowserCrashLog.app.append(BrowserCrashRecord(
                processType: "renderer", kind: exit.kind, status: exit.status, panelID: id, source: .engine
            ))
        case .navigationStarted, .navigationCommitted:
            // A new main-frame document: CEF reports its commit as
            // navigationStarted (OnLoadStart, which runs after the commit).
            enginePageCommitCount &+= 1
            chromiumPageFailure.apply(.navigationCommitted(nil), at: now, paneVisible: isEnginePageVisible)
            finishChromiumHangRecoveryIfNeeded(after: event)
            return
        case .unresponsiveChanged:
            break
        default:
            return
        }
        chromiumPageFailure.apply(event, at: now, paneVisible: isEnginePageVisible)
        finishChromiumHangRecoveryIfNeeded(after: event)
    }

    /// The page's host reports whether the page is on screen. A page that
    /// crashed while hidden reloads here, once shown.
    func noteEnginePageVisibility(_ visible: Bool) {
        let wasVisible = isEnginePageVisible
        isEnginePageVisible = visible
        guard visible, !wasVisible, chromiumPageFailure.failure != nil else { return }
        // The host reports from a view update: change published state after it.
        Task { @MainActor [weak self] in
            guard let self, let enginePage = self.enginePage, self.chromiumPageFailure.paneShown() else { return }
            enginePage.reload()
        }
    }

    /// The recovery prompt for the Chromium page's crash or hang, if shown.
    var chromiumPageFailurePrompt: BrowserPageRecoveryPrompt? {
        guard enginePage != nil, chromiumPageFailure.showsPrompt else { return nil }
        switch chromiumPageFailure.failure {
        case .crashed(let exit, let isRepeat, _)?:
            return .chromiumCrashed(exit, isRepeat: isRepeat)
        case .unresponsive?:
            return .chromiumUnresponsive
        case nil:
            return nil
        }
    }

    /// Reload on the crash page, or Wait on the hang card.
    func performChromiumPageFailurePrimaryAction() {
        guard let enginePage else { return }
        switch chromiumPageFailure.failure {
        case .crashed?:
            chromiumPageFailure.userReloaded()
            enginePage.reload()
        case .unresponsive?:
            chromiumPageFailure.answeredUnresponsive(terminate: false)
            pendingChromiumHangRecovery = nil
            enginePage.answerUnresponsive(terminate: false)
            // A hang cmux found itself (no input, so no Chromium callback to
            // restart): check again, so the card returns if the page still spins.
            probeChromiumResponsiveness()
        case nil:
            break
        }
    }

    /// Exit page on the hang card: ends the renderer; the crash page follows.
    func exitUnresponsiveChromiumPage() {
        guard enginePage != nil, chromiumPageFailure.failure == .unresponsive else { return }
        endHungChromiumRenderer(then: .showCrashPage)
    }
}
