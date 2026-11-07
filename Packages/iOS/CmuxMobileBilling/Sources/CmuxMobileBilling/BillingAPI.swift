import Foundation

/// The cmux web routes the phone uses for App Store billing.
///
/// ``HTTPBillingAPI`` is the production conformance; tests supply a fake so
/// the purchase state machine runs without a network.
public protocol BillingAPI: Sendable {
    /// `POST /api/billing/apple/account-token`.
    /// - Returns: The account's purchase token, eligibility, plan and products.
    /// - Throws: ``BillingAPIError``.
    func accountToken() async throws -> BillingAccount

    /// `POST /api/billing/apple/transactions` with one StoreKit 2 JWS.
    /// - Parameter signedTransactionInfo: `Transaction.jwsRepresentation`.
    /// - Returns: The plan the server applied.
    /// - Throws: ``BillingAPIError``; any throw means the server did not
    ///   accept the transaction and it must not be finished.
    func submitTransaction(signedTransactionInfo: String) async throws -> BillingTransactionReceipt

    /// `POST /api/billing/apple/trial/challenge`: a single-use challenge for
    /// the trial's device proof.
    /// - Returns: The challenge string.
    func trialChallenge() async throws -> String

    /// `POST /api/billing/apple/trial/verify`.
    /// - Parameter request: The proof and the product it is for.
    /// - Returns: Whether the account gets the trial, and its signed
    ///   eligibility.
    func verifyTrial(_ request: BillingTrialVerifyRequest) async throws -> BillingTrialVerification

    /// `GET /api/billing/paywall/variants`, staff only: every live and
    /// retired paywall variant.
    func paywallVariants() async throws -> [BillingPaywallVariant]
}

extension BillingAPI {
    public func trialChallenge() async throws -> String { throw BillingAPIError.rejected(statusCode: 404) }

    public func verifyTrial(_ request: BillingTrialVerifyRequest) async throws -> BillingTrialVerification {
        throw BillingAPIError.rejected(statusCode: 404)
    }

    public func paywallVariants() async throws -> [BillingPaywallVariant] {
        throw BillingAPIError.rejected(statusCode: 404)
    }
}

/// The body of `POST /api/billing/apple/trial/verify`.
public struct BillingTrialVerifyRequest: Sendable, Equatable, Encodable {
    /// The challenge from ``BillingAPI/trialChallenge()``.
    public let challenge: String
    /// The App Attest key id.
    public let keyId: String
    /// The attestation object, base64, the first time a key is used.
    public let attestation: String?
    /// The assertion, base64, for an attested key.
    public let assertion: String?
    /// The DeviceCheck token, base64.
    public let deviceCheckToken: String
    /// The trial product.
    public let productId: String
    /// The `AppTransaction` id; nil before iOS 18.4.
    public let appTransactionId: String?

    /// Creates a request.
    public init(challenge: String, proof: BillingTrialDeviceProof, productID: String, appTransactionID: String?) {
        self.challenge = challenge
        self.keyId = proof.keyID
        self.attestation = proof.attestation
        self.assertion = proof.assertion
        self.deviceCheckToken = proof.deviceCheckToken
        self.productId = productID
        self.appTransactionId = appTransactionID
    }

    enum CodingKeys: String, CodingKey {
        case challenge, keyId, attestation, assertion, deviceCheckToken, productId, appTransactionId
    }

    /// Encodes every key, with JSON null for absent values, as the server
    /// contract lists them.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(challenge, forKey: .challenge)
        try container.encode(keyId, forKey: .keyId)
        try container.encode(attestation, forKey: .attestation)
        try container.encode(assertion, forKey: .assertion)
        try container.encode(deviceCheckToken, forKey: .deviceCheckToken)
        try container.encode(productId, forKey: .productId)
        try container.encode(appTransactionId, forKey: .appTransactionId)
    }
}
