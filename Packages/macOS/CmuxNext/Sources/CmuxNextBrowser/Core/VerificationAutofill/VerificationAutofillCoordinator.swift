import CmuxNextWakeups
public import Foundation

/// Runs email verification AutoFill for the app's browser tabs
/// (plans/cmux-next/email-verification-autofill/DESIGN.md): a tab's detector says its page
/// waits, the coordinator reads the mail source while any page waits, hands each email to the
/// ``VerificationInbox``, shows an offer in the tab's prompt bar, and on the person's click
/// fills the code into the page or opens the link in the same tab.
///
/// Mail has no change signal cmux can subscribe to, so while a page waits (at most the 10-minute
/// window) the source is read every `pollInterval` on the injected clock, each read a one-shot
/// ``DemandTimer`` deadline armed after the last one; the reads end when no page waits or the
/// feature turns off.
///
/// ```swift
/// let coordinator = VerificationAutofillCoordinator(
///     inbox: VerificationInbox(policy: VerificationOfferPolicy(publicSuffixes: list)),
///     source: MailAppVerificationSource(), isEnabled: { setting.enabled })
/// ```
public final class VerificationAutofillCoordinator {
    private let inbox: VerificationInbox
    private let source: any VerificationEmailSource
    private let isEnabled: () -> Bool
    private let now: () -> Date
    private let pollInterval: Duration
    private let pollTimer: DemandTimer

    private var tabs: [BrowserTabID: WeakTab] = [:]
    private var shown: [BrowserTabID: (prompt: BrowserPrompt, emailID: String)] = [:]
    private var responses: [Task<Void, Never>] = []
    /// True while a poll's read runs: no next read is armed until it ends (one osascript at a time).
    private var polling = false

    /// The last error of the mail source (for example ``MailAppVerificationSource/Failure/notAuthorized``),
    /// nil after a good read.
    public private(set) var lastSourceError: (any Error)?

    /// - Parameters:
    ///   - inbox: The waits and offers.
    ///   - source: The mail source the person chose.
    ///   - isEnabled: Reads `browser.verificationAutofill.enabled`.
    ///   - now: The current time (tests pass a fixed one).
    ///   - clock: Paces the reads while a page waits.
    ///   - pollInterval: Time between reads while a page waits.
    public init(inbox: VerificationInbox, source: any VerificationEmailSource, isEnabled: @escaping () -> Bool,
                now: @escaping () -> Date = Date.init, clock: any Clock<Duration> = ContinuousClock(),
                pollInterval: Duration = .seconds(3)) {
        self.inbox = inbox
        self.source = source
        self.isEnabled = isEnabled
        self.now = now
        self.pollInterval = pollInterval
        self.pollTimer = DemandTimer(owner: "VerificationAutofill.poll", clock: clock)
    }

    /// The tab's detector reported that its top frame waits for a verification email.
    /// - Parameter tab: The tab.
    public func pageWaiting(_ tab: any BrowserTab) {
        guard isEnabled(), let url = tab.state.url else { return }
        tabs[tab.id] = WeakTab(tab)
        inbox.pageStartedWaiting(VerificationPageSignal(tab: tab.id, pageURL: url, startedAt: now(), agentDriven: tab.isAgentDriven))
        schedulePoll()
    }

    /// The setting changed: turning it off ends every wait and withdraws every offer.
    public func settingChanged() {
        guard !isEnabled() else { return }
        pollTimer.cancel()
        inbox.clearAll()
        let open = shown.values.map(\.prompt)
        shown.removeAll()
        tabs.removeAll()
        for prompt in open { prompt.respond(.cancel) }
    }

    /// One read of the source and the offers it makes. The poll deadline calls it; tests call it directly.
    func pollOnce() async {
        guard isEnabled() else { return settingChanged() }
        refreshTabs()
        guard let start = inbox.earliestWaitStart else { return }
        let emails: [VerificationEmail]
        do {
            emails = try await source.emails(receivedSince: start.addingTimeInterval(-VerificationOfferPolicy.lookback))
            lastSourceError = nil
        } catch {
            lastSourceError = error
            return
        }
        guard isEnabled() else { return settingChanged() }
        let time = now()
        for email in emails.sorted(by: { $0.receivedAt < $1.receivedAt }) {
            for tab in inbox.receive(email, enabled: true, now: time) { present(on: tab, now: time) }
        }
    }

    /// Waits for the work the person's last clicks started (tests).
    func settle() async {
        let running = responses
        responses.removeAll()
        for task in running { await task.value }
    }

    // MARK: - Private

    /// Arms the next read unless one is pending or running: a source with no change signal is read
    /// once per `pollInterval` only while a page waits and the setting is on, and reads never overlap
    /// (an older read finishing last would replace a newer offer).
    private func schedulePoll() {
        guard !polling else { return }
        pollTimer.scheduleIfIdle(after: pollInterval) { @MainActor [weak self] in
            guard let self else { return }
            self.polling = true
            await self.pollOnce()
            self.polling = false
            guard self.inbox.hasWaitingPages, self.isEnabled() else { return }
            self.schedulePoll()
        }
    }

    /// Ends the waits of closed tabs and of tabs that left their site.
    private func refreshTabs() {
        for (id, weak) in tabs {
            guard let tab = weak.tab else {
                inbox.tabClosed(id)
                tabs[id] = nil
                shown[id] = nil
                continue
            }
            if let url = tab.state.url { inbox.tabNavigated(id, to: url) }
            if let open = shown[id], inbox.pendingOffer(for: id, now: now())?.emailID != open.emailID {
                shown[id] = nil
                open.prompt.respond(.cancel)
            }
        }
    }

    private func present(on id: BrowserTabID, now time: Date) {
        guard let tab = tabs[id]?.tab, let offer = inbox.pendingOffer(for: id, now: time) else { return }
        if let open = shown[id] {
            if open.emailID == offer.emailID { return }
            shown[id] = nil
            open.prompt.respond(.cancel)
        }
        let emailID = offer.emailID
        guard let prompt = tab.offerVerification(offer, completion: { [weak self, weak tab] response in
            guard let self, let tab else { return }
            self.respond(response, emailID: emailID, tab: tab)
        }) else { return }
        shown[id] = (prompt, emailID)
    }

    private func respond(_ response: BrowserPromptResponse, emailID: String, tab: any BrowserTab) {
        if shown[tab.id]?.emailID == emailID { shown[tab.id] = nil }
        switch response {
        case .accept, .allowOnce:
            guard let url = tab.state.url,
                  let offer = inbox.take(for: tab.id, emailID: emailID, currentURL: url, now: now()) else { return }
            if response == .accept, let code = offer.code {
                responses.append(Task { _ = await tab.fillVerificationCode(code) })
            } else if let link = offer.link {
                tab.load(link)
            }
        default:
            inbox.decline(for: tab.id, emailID: emailID)
        }
    }
}

/// A tab the coordinator does not keep alive.
private struct WeakTab {
    weak var tab: (any BrowserTab)?
    init(_ tab: any BrowserTab) { self.tab = tab }
}
