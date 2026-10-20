public import Foundation

/// The one rule for email verification AutoFill: may this email's code or
/// link be offered on this waiting page? Each rule of
/// plans/cmux-next/email-verification-autofill/DESIGN.md "Matching" is one
/// ``VerificationOfferRejection`` case, checked in order.
///
/// The core rule is **same site**: the registrable domain of the sender's
/// address equals the page's (full Public Suffix List). A phishing page on
/// another site never gets the real site's code. An origin-bound line
/// (`@login.example.com #123456`) instead binds the code to that exact host.
///
/// ```swift
/// let policy = VerificationOfferPolicy(publicSuffixes: list)
/// switch policy.offer(for: email, on: signal, enabled: true, now: .now) {
/// case .success(let offer): inbox.show(offer)
/// case .failure(let reason): break // e.g. .differentSite
/// }
/// ```
public nonisolated struct VerificationOfferPolicy: Sendable {
    /// How long before the page asked an email may have arrived (clock skew, fast senders).
    public static let lookback: TimeInterval = 60
    /// How long after the page asked an email may arrive, and how long an offer lives.
    public static let window: TimeInterval = 600

    private let publicSuffixes: PublicSuffixList
    private let parser: VerificationMessageParser

    /// - Parameters:
    ///   - publicSuffixes: The list that decides sites (``PublicSuffixList/bundled()`` in the app).
    ///   - parser: Reads codes and links from an email.
    public init(publicSuffixes: PublicSuffixList, parser: VerificationMessageParser = VerificationMessageParser()) {
        self.publicSuffixes = publicSuffixes
        self.parser = parser
    }

    /// Decides one email against one waiting page.
    /// - Parameters:
    ///   - email: The email a source read.
    ///   - signal: The waiting page.
    ///   - enabled: The `browser.verificationAutofill.enabled` setting.
    ///   - now: The current time.
    /// - Returns: The offer, or the first rule the email breaks.
    public func offer(for email: VerificationEmail, on signal: VerificationPageSignal, enabled: Bool, now: Date)
        -> Result<VerificationOffer, VerificationOfferRejection>
    {
        guard enabled else { return .failure(.featureOff) }
        guard !signal.agentDriven else { return .failure(.agentDrivenTab) }
        guard signal.pageURL.scheme?.lowercased() == "https", let pageHost = signal.pageURL.host?.lowercased(), !pageHost.isEmpty
        else { return .failure(.insecurePage) }
        guard let pageSite = publicSuffixes.registrableDomain(of: pageHost) else { return .failure(.pageHasNoSite) }
        guard let senderSite = Self.domain(ofAddress: email.senderAddress).flatMap(publicSuffixes.registrableDomain(of:))
        else { return .failure(.senderHasNoSite) }

        let message = parser.parse(email)
        let sameSite = senderSite == pageSite
        if let bound = message.originBoundCode {
            guard bound.host == pageHost else { return .failure(.originBoundToAnotherHost) }
        } else if !sameSite {
            return .failure(.differentSite)
        }
        if email.senderAuthenticated == false { return .failure(.senderFailedAuthentication) }

        if email.receivedAt < signal.startedAt.addingTimeInterval(-Self.lookback) { return .failure(.receivedBeforePageAsked) }
        if email.receivedAt > signal.startedAt.addingTimeInterval(Self.window) { return .failure(.receivedAfterWindow) }
        let expiresAt = email.receivedAt.addingTimeInterval(Self.window)
        if now > expiresAt { return .failure(.expired) }

        // An origin-bound code is the code; otherwise exactly one code word code.
        let codes = message.originBoundCode.map { [$0.code] } ?? message.codes
        // A link needs the same site and an authenticated sender: a spoofed sender could plant one.
        let links = sameSite && email.senderAuthenticated == true
            ? message.links.filter { isVerificationLink($0, site: pageSite) }
            : []
        guard codes.count <= 1, links.count <= 1 else { return .failure(.ambiguous) }
        guard !codes.isEmpty || !links.isEmpty else { return .failure(.nothingToOffer) }

        return .success(VerificationOffer(
            emailID: email.id, tab: signal.tab, senderSite: pageSite, pageOrigin: Self.origin(scheme: "https", host: pageHost, port: signal.pageURL.port),
            code: codes.first, link: links.first, expiresAt: expiresAt
        ))
    }

    /// The registrable domain of an https URL's host, or nil (any other
    /// scheme, no host, no site). The inbox compares it to an offer's
    /// ``VerificationOffer/senderSite`` when the person clicks.
    /// - Parameter url: A page URL.
    /// - Returns: Its site, or nil.
    public func site(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return publicSuffixes.registrableDomain(of: host)
    }

    /// A same-site https link whose path or query names a verification step,
    /// and not an unsubscribe, settings or legal link.
    private func isVerificationLink(_ url: URL, site: String) -> Bool {
        guard self.site(of: url) == site else { return false }
        let target = (url.path + "?" + (url.query ?? "")).lowercased()
        let excluded = ["unsubscribe", "optout", "opt-out", "preferences", "privacy", "terms", "/help", "support", "notifications"]
        guard !excluded.contains(where: target.contains) else { return false }
        let steps = ["verif", "confirm", "magic", "login", "signin", "sign-in", "sign_in", "auth", "token", "activate", "validat", "otp", "passwordless", "reset"]
        return steps.contains(where: target.contains)
    }

    /// The domain of `user@domain` (a bare address, not a display name), lowercased.
    private static func domain(ofAddress address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        return parts[1].lowercased()
    }

    private static func origin(scheme: String, host: String, port: Int?) -> String {
        guard let port, port != 443 else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }
}
