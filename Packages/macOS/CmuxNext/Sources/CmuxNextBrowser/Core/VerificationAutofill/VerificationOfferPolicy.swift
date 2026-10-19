public import Foundation

/// The matching rules. Stub: the red commit of its tests.
public nonisolated struct VerificationOfferPolicy: Sendable {
    public init(publicSuffixes: PublicSuffixList, parser: VerificationMessageParser = VerificationMessageParser()) {}
    public func offer(for email: VerificationEmail, on signal: VerificationPageSignal, enabled: Bool, now: Date) -> Result<VerificationOffer, VerificationOfferRejection> {
        .failure(.nothingToOffer)
    }
    public func sameSite(_ url: URL, as origin: String) -> Bool { true }
}
