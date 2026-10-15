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
/// pane stays frozen until it is closed.
///
/// - A reload or navigation starts a responsiveness probe. When the page does
///   not answer a trivial script within `chromiumHangProbeTimeout` and no new
///   document started meanwhile, the pane shows the "Page unresponsive" card.
///   The probe never ends a renderer by itself: a page can be legitimately
///   busy, or blocked in a "Leave site?" dialog guarding unsaved work, and
///   Chrome asks first too.
/// - With the card showing, Exit page, a second Reload or a navigation (the
///   person's or an agent's explicit choice) ends the hung renderer, through
///   Chromium's hang callback when it has one and otherwise by ending the
///   page's renderer process, then runs the reload or navigation in a new one.
/// - Wait clears the card and probes again.
///
/// WebKit panels keep their own recovery (`BrowserPanel+AutomationRecovery.swift`).
extension BrowserPanel {
    /// How long a Chromium page may take to answer a trivial script before
    /// the card offers to end it.
    static let chromiumHangProbeTimeout: Duration = .seconds(8)

    /// Reloads the Chromium page; on a page the card marks hung, ends the
    /// renderer first and reloads in a new one.
    func reloadEnginePageRecoveringHang(fromOrigin: Bool) {
        guard let enginePage else { return }
        let action = ChromiumHangRecoveryAction.reload(fromOrigin: fromOrigin)
        if chromiumPageFailure.failure == .unresponsive {
            endHungChromiumRenderer(then: action)
            return
        }
        pendingChromiumHangRecovery = nil
        if case .crashed = chromiumPageFailure.failure { chromiumPageFailure.userReloaded() }
        if fromOrigin { enginePage.reloadFromOrigin() } else { enginePage.reload() }
        probeChromiumResponsiveness()
    }

    /// Loads a request; on a page the card marks hung, ends the renderer
    /// first and loads in a new one.
    func loadEnginePageRecoveringHang(_ request: URLRequest) {
        guard let enginePage else { return }
        let action = ChromiumHangRecoveryAction.load(request)
        if chromiumPageFailure.failure == .unresponsive {
            endHungChromiumRenderer(then: action)
            return
        }
        pendingChromiumHangRecovery = nil
        if case .crashed = chromiumPageFailure.failure { chromiumPageFailure.userReloaded() }
        enginePage.load(request)
        probeChromiumResponsiveness()
    }

    /// Asks the page to run a trivial script; when it does not answer within
    /// the timeout and no new document started meanwhile, the card shows.
    func probeChromiumResponsiveness(
        timeout: Duration = BrowserPanel.chromiumHangProbeTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        guard let enginePage else { return }
        chromiumHangProbeTask?.cancel()
        let documentsBefore = enginePageCommitCount
        chromiumHangProbeTask = Task { @MainActor [weak self] in
            let answered = await Self.answersScript(enginePage, within: timeout, clock: clock)
            guard let self, !Task.isCancelled, !answered,
                  self.enginePage === enginePage,
                  self.enginePageCommitCount == documentsBefore,
                  self.chromiumPageFailure.failure == nil
            else { return }
            self.chromiumPageFailure.apply(.unresponsiveChanged(true), at: Date(), paneVisible: self.isEnginePageVisible)
        }
    }

    /// Whether `page` answers `1` within `timeout`. Whichever side finishes
    /// first cancels the other.
    private static func answersScript(
        _ page: any BrowserPage,
        within timeout: Duration,
        clock: any Clock<Duration>
    ) async -> Bool {
        let once = ChromiumProbeOnce()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            once.evaluation = Task { @MainActor in
                _ = try? await page.evaluateJavaScript("1", in: .page)
                once.finish(true)
            }
            once.timer = Task { @MainActor in
                do {
                    try await clock.sleep(for: timeout)
                    once.finish(false)
                } catch {
                    // Cancelled because the page answered.
                }
            }
        }
    }

    /// Ends the hung renderer; `action` runs once its end arrives.
    func endHungChromiumRenderer(then action: ChromiumHangRecoveryAction) {
        guard let enginePage else { return }
        chromiumHangProbeTask?.cancel()
        chromiumHangProbeTask = nil
        chromiumPageFailure.answeredUnresponsive(terminate: true)
        // Chromium's own hang callback, when it has one (input went unanswered).
        enginePage.answerUnresponsive(terminate: true)
        // Without one (no input was sent), end the page's renderer process: a
        // direct child of cmux, checked to still be a tab renderer right before.
        let pid = (enginePage as? any BrowserPageMemoryReclaiming)?.contentProcessIdentifier
        if let pid, pid > 0, ChromiumHelperIdentity.read(pid: Int32(pid))?.processType == "renderer" {
            pendingChromiumHangRecovery = action
            kill(pid_t(pid), SIGKILL)
        } else if case .showCrashPage = action {
            // Nothing to end but a callback that may not exist; the card stays
            // until the page answers or the person reloads.
            pendingChromiumHangRecovery = action
        } else {
            // No renderer to end: try the action directly rather than wait for
            // an end that never comes.
            pendingChromiumHangRecovery = nil
            chromiumPageFailure.userReloaded()
            perform(action, on: enginePage)
        }
    }

    /// Runs or drops the pending recovery after a page event: it runs once the
    /// hung renderer has ended, and is dropped when the page moved on by
    /// itself (a new document, or it answered again).
    func finishChromiumHangRecoveryIfNeeded(after event: BrowserPageEvent) {
        guard let action = pendingChromiumHangRecovery, let enginePage else { return }
        switch event {
        case .processTerminated:
            pendingChromiumHangRecovery = nil
            guard action != .showCrashPage else { return }
            chromiumPageFailure.userReloaded()
            perform(action, on: enginePage)
        case .navigationStarted, .navigationCommitted, .unresponsiveChanged(false):
            pendingChromiumHangRecovery = nil
        default:
            break
        }
    }

    private func perform(_ action: ChromiumHangRecoveryAction, on enginePage: any BrowserPage) {
        switch action {
        case .reload(let fromOrigin):
            if fromOrigin { enginePage.reloadFromOrigin() } else { enginePage.reload() }
        case .load(let request):
            enginePage.load(request)
        case .showCrashPage:
            break
        }
    }

    /// Stops hang work for a page that is closing.
    func cancelChromiumHangRecovery() {
        chromiumHangProbeTask?.cancel()
        chromiumHangProbeTask = nil
        pendingChromiumHangRecovery = nil
    }

    /// An agent's call into the Chromium page timed out: check whether the
    /// page is hung, so the card shows and the next reload or navigation
    /// recovers it.
    func noteChromiumAutomationTimeout() {
        guard enginePage != nil, chromiumPageFailure.failure == nil else { return }
        probeChromiumResponsiveness(timeout: .seconds(2))
    }
}

/// Resumes a probe's continuation once, with whichever answer comes first,
/// and cancels the other side.
@MainActor
private final class ChromiumProbeOnce {
    var continuation: CheckedContinuation<Bool, Never>?
    var evaluation: Task<Void, Never>?
    var timer: Task<Void, Never>?

    func finish(_ answered: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: answered)
        if answered { timer?.cancel() } else { evaluation?.cancel() }
    }
}
