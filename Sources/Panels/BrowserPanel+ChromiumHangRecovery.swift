import CmuxBrowser
import Darwin
import Foundation

/// What a Chromium panel does once it has ended a hung renderer.
enum ChromiumHangRecoveryAction: Equatable {
    /// Reload the page (the person or an agent pressed Reload).
    case reload(fromOrigin: Bool)
    /// Load a request (the person or an agent navigated).
    case load(URLRequest)
    /// Nothing more: Exit page shows the crash page with Reload.
    case showCrashPage
}

/// Recovery from a hung Chromium renderer (a JS infinite loop).
///
/// Chromium only reports a hang when input goes unanswered, and a hung
/// renderer never acknowledges a reload or a navigation, so without this the
/// pane stays frozen until it is closed. A reload or navigation in a Chromium
/// panel starts a responsiveness probe: when the page does not answer a
/// trivial script within `chromiumHangProbeTimeout`, the panel shows the
/// "Page unresponsive" card, ends the renderer and then performs the reload or
/// navigation in a new one, as Chrome's Exit page does. A reload or navigation
/// while the card shows does the same at once. Exit page ends the renderer
/// even when Chromium has no pending hang callback (an agent-only session
/// sends no input), by ending the page's renderer process. WebKit panels keep
/// their own recovery (`BrowserPanel+AutomationRecovery.swift`).
extension BrowserPanel {
    /// How long a Chromium page may take to answer a trivial script before it
    /// counts as hung. Chromium's own input hang timeout is 15 s; a page that
    /// is merely busy loading still answers a script within this.
    static let chromiumHangProbeTimeout: Duration = .seconds(8)

    /// Reloads the Chromium page, recovering it first when it is hung.
    func reloadEnginePageRecoveringHang(fromOrigin: Bool) {
        guard let enginePage else { return }
        let action = ChromiumHangRecoveryAction.reload(fromOrigin: fromOrigin)
        if chromiumPageFailure.failure == .unresponsive {
            endHungChromiumRenderer(then: action)
            return
        }
        if fromOrigin { enginePage.reloadFromOrigin() } else { enginePage.reload() }
        probeChromiumResponsiveness(recovering: action)
    }

    /// Loads a request in the Chromium page, recovering it first when it is hung.
    func loadEnginePageRecoveringHang(_ request: URLRequest) {
        guard let enginePage else { return }
        let action = ChromiumHangRecoveryAction.load(request)
        if chromiumPageFailure.failure == .unresponsive {
            endHungChromiumRenderer(then: action)
            return
        }
        enginePage.load(request)
        probeChromiumResponsiveness(recovering: action)
    }

    /// Asks the page to run a trivial script; when it does not answer within
    /// the timeout and no new document committed meanwhile, the page is hung:
    /// the card shows, and with an `action` the panel also recovers with it.
    func probeChromiumResponsiveness(
        recovering action: ChromiumHangRecoveryAction?,
        timeout: Duration = BrowserPanel.chromiumHangProbeTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        guard let enginePage else { return }
        chromiumHangProbeTask?.cancel()
        let commitsBefore = enginePageCommitCount
        chromiumHangProbeTask = Task { @MainActor [weak self] in
            let answered = await Self.answersScript(enginePage, within: timeout, clock: clock)
            guard let self, !Task.isCancelled, !answered,
                  self.enginePageCommitCount == commitsBefore,
                  self.chromiumPageFailure.failure == nil || self.chromiumPageFailure.failure == .unresponsive
            else { return }
            self.chromiumPageFailure.apply(.unresponsiveChanged(true), at: Date(), paneVisible: self.isEnginePageVisible)
            if let action { self.endHungChromiumRenderer(then: action) }
        }
    }

    /// Whether `page` answers `1` within `timeout`.
    private static func answersScript(
        _ page: any BrowserPage,
        within timeout: Duration,
        clock: any Clock<Duration>
    ) async -> Bool {
        let once = ChromiumProbeOnce()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            Task { @MainActor in
                _ = try? await page.evaluateJavaScript("1", in: .page)
                once.finish(true)
            }
            Task { @MainActor in
                try? await clock.sleep(for: timeout)
                once.finish(false)
            }
        }
    }

    /// Ends the hung renderer; `action` runs once its end arrives.
    func endHungChromiumRenderer(then action: ChromiumHangRecoveryAction) {
        guard let enginePage else { return }
        chromiumHangProbeTask?.cancel()
        chromiumHangProbeTask = nil
        pendingChromiumHangRecovery = action
        chromiumPageFailure.answeredUnresponsive(terminate: true)
        // Chromium's own hang callback, when it has one (input went unanswered).
        enginePage.answerUnresponsive(terminate: true)
        // Without one (no input was sent), end the page's renderer process; the
        // app owns it as a child.
        if let pid = (enginePage as? any BrowserPageMemoryReclaiming)?.contentProcessIdentifier, pid > 0 {
            kill(pid_t(pid), SIGKILL)
        }
    }

    /// Runs the pending recovery once the hung renderer has ended.
    func finishChromiumHangRecoveryIfNeeded(after event: BrowserPageEvent) {
        guard case .processTerminated = event, let action = pendingChromiumHangRecovery,
              let enginePage else { return }
        pendingChromiumHangRecovery = nil
        switch action {
        case .reload(let fromOrigin):
            chromiumPageFailure.userReloaded()
            if fromOrigin { enginePage.reloadFromOrigin() } else { enginePage.reload() }
        case .load(let request):
            chromiumPageFailure.userReloaded()
            enginePage.load(request)
        case .showCrashPage:
            break
        }
    }

    /// An agent's call into the Chromium page timed out: check whether the
    /// page is hung, so the card shows and the next reload or navigation
    /// recovers it.
    func noteChromiumAutomationTimeout() {
        guard enginePage != nil, chromiumPageFailure.failure == nil else { return }
        probeChromiumResponsiveness(recovering: nil, timeout: .seconds(2))
    }
}

/// Resumes a probe's continuation once, with whichever answer comes first.
@MainActor
private final class ChromiumProbeOnce {
    var continuation: CheckedContinuation<Bool, Never>?

    func finish(_ answered: Bool) {
        continuation?.resume(returning: answered)
        continuation = nil
    }
}
