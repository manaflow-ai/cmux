public import Foundation

/// The pages waiting for a verification email and the offers made to them,
/// in memory only (plans/cmux-next/email-verification-autofill/DESIGN.md).
/// An email gives each waiting tab of its site at most one offer; taking or
/// declining it on one tab uses it up on all. Offers end on expiry, on a
/// navigation to another site, when the tab closes, and on ``clearAll()``
/// (the setting turned off). Nothing here is written to disk or logged.
public final class VerificationInbox {
    private let policy: VerificationOfferPolicy
    private var waiting: [BrowserTabID: VerificationPageSignal] = [:]
    private var offers: [BrowserTabID: VerificationOffer] = [:]
    /// Ids of emails already used or declined (ids only, never their text), oldest first.
    private var used: [String] = []
    private static let usedLimit = 256

    /// - Parameter policy: Decides which email may be offered on which page.
    public init(policy: VerificationOfferPolicy) {
        self.policy = policy
    }

    /// The tab's top frame started waiting for an email. A tab that already
    /// waits on the same site keeps its earlier start, so a page that
    /// reports again does not move the time window.
    /// - Parameter signal: The waiting page.
    public func pageStartedWaiting(_ signal: VerificationPageSignal) {
        if let current = waiting[signal.tab], let site = policy.site(of: current.pageURL), site == policy.site(of: signal.pageURL) { return }
        waiting[signal.tab] = signal
    }

    /// True while some tab waits for an email: a source is read only then.
    public var hasWaitingPages: Bool { !waiting.isEmpty }

    /// When the earliest current wait started, or nil when none waits.
    public var earliestWaitStart: Date? { waiting.values.map(\.startedAt).min() }

    /// The tab's top frame navigated. Another site ends its wait and drops its offer.
    /// - Parameters:
    ///   - tab: The tab.
    ///   - url: Its new top-frame URL.
    public func tabNavigated(_ tab: BrowserTabID, to url: URL) {
        let site = policy.site(of: url)
        if let signal = waiting[tab], site == nil || policy.site(of: signal.pageURL) != site { waiting[tab] = nil }
        if let offer = offers[tab], site != offer.senderSite { offers[tab] = nil }
    }

    /// The tab closed: its wait and offer end.
    /// - Parameter tab: The tab.
    public func tabClosed(_ tab: BrowserTabID) {
        waiting[tab] = nil
        offers[tab] = nil
    }

    /// Ends every wait and offer (the setting turned off).
    public func clearAll() {
        waiting.removeAll()
        offers.removeAll()
    }

    /// A source read `email`: offers it on every waiting tab the policy allows.
    /// A newer email replaces a tab's older offer.
    /// - Parameters:
    ///   - email: The email.
    ///   - enabled: The `browser.verificationAutofill.enabled` setting.
    ///   - now: The current time.
    /// - Returns: The tabs that got an offer, sorted by id.
    @discardableResult
    public func receive(_ email: VerificationEmail, enabled: Bool, now: Date) -> [BrowserTabID] {
        guard enabled, !used.contains(email.id) else { return [] }
        waiting = waiting.filter { now <= $0.value.startedAt.addingTimeInterval(VerificationOfferPolicy.window) }
        var offered: [BrowserTabID] = []
        for (tab, signal) in waiting.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard case .success(let offer) = policy.offer(for: email, on: signal, enabled: enabled, now: now) else { continue }
            offers[tab] = offer
            offered.append(tab)
        }
        return offered
    }

    /// The tab's offer to show, or nil (none, or expired).
    /// - Parameters:
    ///   - tab: The tab.
    ///   - now: The current time.
    public func pendingOffer(for tab: BrowserTabID, now: Date) -> VerificationOffer? {
        guard let offer = offers[tab] else { return nil }
        guard now <= offer.expiresAt else {
            offers[tab] = nil
            return nil
        }
        return offer
    }

    /// The person clicked Fill Code or Open Link: hands out the offer once,
    /// when it has not expired and the tab still shows its site, and uses
    /// the email up everywhere. Nil otherwise (and the offer is dropped).
    /// - Parameters:
    ///   - tab: The tab.
    ///   - emailID: The email of the offer the person saw; another (a newer email replaced
    ///     it) gives nil and keeps the newer offer. Nil takes whichever offer the tab has.
    ///   - currentURL: The tab's top-frame URL at the click.
    ///   - now: The current time.
    public func take(for tab: BrowserTabID, emailID: String? = nil, currentURL: URL, now: Date) -> VerificationOffer? {
        guard let current = offers[tab], emailID == nil || current.emailID == emailID else { return nil }
        guard let offer = offers.removeValue(forKey: tab) else { return nil }
        guard now <= offer.expiresAt, policy.site(of: currentURL) == offer.senderSite else { return nil }
        use(offer.emailID)
        waiting[tab] = nil
        return offer
    }

    /// The person clicked Not Now: the email is used up everywhere.
    /// - Parameters:
    ///   - tab: The tab.
    ///   - emailID: The email of the offer the person saw; another gives no change.
    public func decline(for tab: BrowserTabID, emailID: String? = nil) {
        guard let current = offers[tab], emailID == nil || current.emailID == emailID else { return }
        guard let offer = offers.removeValue(forKey: tab) else { return }
        use(offer.emailID)
    }

    private func use(_ emailID: String) {
        offers = offers.filter { $0.value.emailID != emailID }
        used.append(emailID)
        if used.count > Self.usedLimit { used.removeFirst(used.count - Self.usedLimit) }
    }
}
