public import Foundation

/// Runs email verification AutoFill for the app's browser tabs
/// (plans/cmux-next/email-verification-autofill/DESIGN.md): a tab's detector says its page
/// waits, the coordinator reads the mail source while any page waits, hands each email to the
/// ``VerificationInbox``, shows an offer in the tab's prompt bar, and on the person's click
/// fills the code into the page or opens the link in the same tab.
///
/// Mail has no change signal cmux can subscribe to, so while a page waits (at most the 10-minute
/// window) the source is read every `pollInterval` on the injected clock; the loop ends when no
/// page waits or the feature turns off.
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
    private let clock: any Clock<Duration>
    private let pollInterval: Duration

    private var tabs: [BrowserTabID: WeakTab] = [:]
    private var shown: [BrowserTabID: (prompt: BrowserPrompt, emailID: String)] = [:]
    private var loop: Task<Void, Never>?
    private var responses: [Task<Void, Never>] = []

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
        self.clock = clock
        self.pollInterval = pollInterval
    }

    /// The tab's detector reported that its top frame waits for a verification email.
    /// - Parameter tab: The tab.
    public func pageWaiting(_ tab: any BrowserTab) {
        guard isEnabled(), let url = tab.state.url else { return }
        tabs[tab.id] = WeakTab(tab)
        inbox.pageStartedWaiting(VerificationPageSignal(tab: tab.id, pageURL: url, startedAt: now(), agentDriven: tab.isAgentDriven))
        startLoop()
    }

    /// The setting changed: turning it off ends every wait and withdraws every offer.
    public func settingChanged() {
        guard !isEnabled() else { return }
        loop?.cancel()
        loop = nil
        inbox.clearAll()
        let open = shown.values.map(\.prompt)
        shown.removeAll()
        tabs.removeAll()
        for prompt in open { prompt.respond(.cancel) }
    }

    /// One read of the source and the offers it makes. The loop calls it; tests call it directly.
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

    private func startLoop() {
        guard loop == nil else { return }
        let (clock, interval) = (clock, pollInterval)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                // A bounded, cancellable pause between reads of an external source with no change
                // signal; the loop ends when no page waits or the setting turns off.
                do { try await clock.sleep(for: interval) } catch { return }
                guard let self else { return }
                await self.pollOnce()
                guard self.inbox.hasWaitingPages, self.isEnabled() else { self.loop = nil; return }
            }
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
