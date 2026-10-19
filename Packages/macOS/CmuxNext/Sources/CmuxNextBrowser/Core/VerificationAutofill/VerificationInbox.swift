public import Foundation

/// Waiting pages and their offers. Stub: the red commit of its tests.
public final class VerificationInbox {
    public init(policy: VerificationOfferPolicy) {}
    public func pageStartedWaiting(_ signal: VerificationPageSignal) {}
    public func tabNavigated(_ tab: BrowserTabID, to url: URL) {}
    public func tabClosed(_ tab: BrowserTabID) {}
    public func clearAll() {}
    @discardableResult
    public func receive(_ email: VerificationEmail, enabled: Bool, now: Date) -> [BrowserTabID] { [] }
    public func pendingOffer(for tab: BrowserTabID, now: Date) -> VerificationOffer? { nil }
    public func take(for tab: BrowserTabID, currentURL: URL, now: Date) -> VerificationOffer? { nil }
    public func decline(for tab: BrowserTabID) {}
}
