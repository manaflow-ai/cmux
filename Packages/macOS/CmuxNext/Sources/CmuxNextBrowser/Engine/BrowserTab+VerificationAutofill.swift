import Foundation

/// The tab side of email verification AutoFill (plans/cmux-next/email-verification-autofill/DESIGN.md).
extension BrowserTab {
    /// Shows `offer` in the tab's prompt bar. Returns the prompt, or nil when this engine has no
    /// prompt bar (then `completion` never runs).
    /// - Parameters:
    ///   - offer: The offer.
    ///   - completion: The person's answer: `.accept` (Fill Code), `.allowOnce` (Open Link), `.cancel`.
    @discardableResult
    public func offerVerification(_ offer: VerificationOffer, completion: @escaping (BrowserPromptResponse) -> Void) -> BrowserPrompt? {
        let kind = BrowserPromptKind.verificationOffer(offer)
        if let tab = self as? WebKitTab {
            tab.enqueuePrompt(kind, origin: offer.pageOrigin, completion: completion)
        } else if let tab = self as? CEFTab {
            tab.enqueuePrompt(kind, origin: offer.pageOrigin, completion: completion)
        } else if let tab = self as? MockBrowserTab {
            tab.enqueuePrompt(kind, origin: offer.pageOrigin, completion: completion)
        } else {
            return nil
        }
        return pendingPrompts.last { if case .verificationOffer(let shown) = $0.kind { shown == offer } else { false } }
    }

    /// Types `code` into the page's code field from an isolated world
    /// (``VerificationPageScripts/fillScript(code:)``); never submits. True when a field took it.
    /// - Parameter code: The code.
    public func fillVerificationCode(_ code: String) async -> Bool {
        (try? await evaluate(VerificationPageScripts.fillScript(code: code), world: .isolated, gesture: .cmux)) == .bool(true)
    }
}
