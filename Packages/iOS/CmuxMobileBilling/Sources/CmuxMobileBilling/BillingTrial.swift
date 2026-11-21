import Foundation

/// The allowances of a free trial, as the server reports them. Every field is
/// optional so a server that omits one still decodes; the app shows only the
/// fields it received.
public struct BillingTrialLimits: Sendable, Equatable, Hashable, Codable {
    /// Cloud machines at once.
    public let machines: Int?
    /// vCPUs per machine.
    public let vcpus: Int?
    /// RAM per machine, in GB.
    public let memoryGb: Int?
    /// Machine hours in the trial.
    public let vmHours: Int?

    /// Creates limits.
    public init(machines: Int?, vcpus: Int?, memoryGb: Int?, vmHours: Int?) {
        self.machines = machines
        self.vcpus = vcpus
        self.memoryGb = memoryGb
        self.vmHours = vmHours
    }
}

/// The account-token response's `trial` object: the server says this account
/// may get a free trial if the device proof passes. It is not a grant; the
/// app shows no trial text until ``BillingModel/trial`` is
/// ``BillingTrialState/available(_:)``.
public struct BillingTrialOffer: Sendable, Equatable, Codable {
    /// True when the server offers a trial.
    public let offered: Bool
    /// The plan the trial is for.
    public let planID: BillingPlanID
    /// The billing period of the trial product; nil reads it from the
    /// product id.
    public let billingPeriod: BillingPeriod?
    /// The App Store product that carries the free-trial introductory offer,
    /// such as `com.cmux.app.pro.trial.monthly`. It is a separate product
    /// priced like the plan's monthly product; normal products carry no
    /// introductory offer. Nil means no trial.
    public let productID: String?
    /// Whether the server needs App Attest and DeviceCheck proof first.
    public let attestRequired: Bool
    /// The trial's allowances.
    public let limits: BillingTrialLimits?

    /// Creates an offer.
    public init(
        offered: Bool,
        planID: BillingPlanID,
        billingPeriod: BillingPeriod?,
        productID: String?,
        attestRequired: Bool,
        limits: BillingTrialLimits?
    ) {
        self.offered = offered
        self.planID = planID
        self.billingPeriod = billingPeriod
        self.productID = productID
        self.attestRequired = attestRequired
        self.limits = limits
    }

    enum CodingKeys: String, CodingKey {
        case offered
        case planID = "planId"
        case billingPeriod
        case productID = "productId"
        case attestRequired
        case limits
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offered = try container.decode(Bool.self, forKey: .offered)
        planID = try container.decode(BillingPlanID.self, forKey: .planID)
        billingPeriod = (try? container.decodeIfPresent(String.self, forKey: .billingPeriod)).flatMap { $0 }
            .flatMap(BillingPeriod.init(rawValue:))
        productID = try container.decodeIfPresent(String.self, forKey: .productID)
        // Proof is required unless the server explicitly says otherwise.
        attestRequired = try container.decodeIfPresent(Bool.self, forKey: .attestRequired) ?? true
        limits = try? container.decodeIfPresent(BillingTrialLimits.self, forKey: .limits)
    }
}

/// A trial the account is in now: `currentPlan.trial`.
public struct BillingActiveTrial: Sendable, Equatable, Codable {
    /// When the trial ends and the paid plan starts; nil when unknown.
    public let endsAt: Date?
    /// The trial's allowances.
    public let limits: BillingTrialLimits?

    /// Creates an active trial.
    public init(endsAt: Date?, limits: BillingTrialLimits?) {
        self.endsAt = endsAt
        self.limits = limits
    }

    enum CodingKeys: String, CodingKey {
        case endsAt
        case limits
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(String.self, forKey: .endsAt)
        endsAt = raw.flatMap(Self.parseDate)
        limits = try? container.decodeIfPresent(BillingTrialLimits.self, forKey: .limits)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(endsAt.map { ISO8601DateFormatter().string(from: $0) }, forKey: .endsAt)
        try container.encodeIfPresent(limits, forKey: .limits)
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// The device proof for a trial: an App Attest attestation (first use of a
/// key) or assertion (later uses), plus a DeviceCheck token.
public struct BillingTrialDeviceProof: Sendable, Equatable {
    /// The App Attest key id.
    public let keyID: String
    /// The attestation object, base64; only the first time a key is used.
    public let attestation: String?
    /// The assertion, base64; when the key was attested before.
    public let assertion: String?
    /// The DeviceCheck token, base64.
    public let deviceCheckToken: String

    /// Creates a proof.
    public init(keyID: String, attestation: String?, assertion: String?, deviceCheckToken: String) {
        self.keyID = keyID
        self.attestation = attestation
        self.assertion = assertion
        self.deviceCheckToken = deviceCheckToken
    }
}

/// Why a device proof could not be made.
public enum BillingTrialProofError: Error, Sendable, Equatable {
    /// App Attest or DeviceCheck is not available (Simulator, old device).
    case unsupported
    /// App Attest failed to make or use a key.
    case attest
    /// DeviceCheck failed to make a token.
    case deviceCheck
}

/// Makes the App Attest and DeviceCheck proof a trial needs. The live
/// conformance is ``LiveTrialDeviceProver``; it is a seam so the model runs
/// without DeviceCheck.
public protocol BillingTrialDeviceProving: Sendable {
    /// Whether this device can make the proof. False in the Simulator.
    var isSupported: Bool { get async }
    /// Makes a proof bound to `clientData`.
    /// - Parameter clientData: The bytes the server hashes and checks:
    ///   the challenge then the product id, UTF-8.
    /// - Returns: The proof.
    /// - Throws: ``BillingTrialProofError``.
    func proof(clientData: Data) async throws -> BillingTrialDeviceProof
    /// Forgets the stored App Attest key, so the next proof attests a new one.
    func resetKey() async
}

/// The server's answer to a trial proof.
public struct BillingTrialVerification: Sendable, Equatable, Decodable {
    /// Whether the account gets the trial.
    public let eligible: Bool
    /// The server-signed introductory offer eligibility, for
    /// `Product.PurchaseOption.introductoryOfferEligibility(compactJWS:)`.
    public let introductoryOfferJWS: String?
    /// Whether the app may show the trial on iOS before 18.4, where the
    /// signed eligibility cannot be passed to StoreKit.
    public let legacyTrialAllowed: Bool
    /// Why the trial was refused.
    public let reason: String?

    /// Creates a verification.
    public init(eligible: Bool, introductoryOfferJWS: String?, legacyTrialAllowed: Bool, reason: String?) {
        self.eligible = eligible
        self.introductoryOfferJWS = introductoryOfferJWS
        self.legacyTrialAllowed = legacyTrialAllowed
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case eligible
        case introductoryOfferJWS
        case legacyTrialAllowed
        case reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eligible = try container.decode(Bool.self, forKey: .eligible)
        introductoryOfferJWS = try container.decodeIfPresent(String.self, forKey: .introductoryOfferJWS)
        legacyTrialAllowed = try container.decodeIfPresent(Bool.self, forKey: .legacyTrialAllowed) ?? false
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// A trial the paywall may show: the server verified the device and granted
/// it, and StoreKit has a free-trial introductory offer for the product.
public struct BillingTrialGrant: Sendable, Equatable, Hashable {
    /// The product that carries the trial.
    public let productID: String
    /// The plan the trial is for.
    public let planID: BillingPlanID
    /// The signed eligibility to pass to StoreKit; nil on the legacy path.
    public let introductoryOfferJWS: String?
    /// The StoreKit trial product, priced like the plan's monthly product.
    public let product: StoreProduct
    /// The StoreKit free-trial offer.
    public let offer: StoreIntroductoryOffer
    /// The trial's allowances from the server.
    public let limits: BillingTrialLimits?

    /// Creates a grant.
    public init(
        planID: BillingPlanID,
        product: StoreProduct,
        introductoryOfferJWS: String?,
        offer: StoreIntroductoryOffer,
        limits: BillingTrialLimits?
    ) {
        self.productID = product.id
        self.planID = planID
        self.product = product
        self.introductoryOfferJWS = introductoryOfferJWS
        self.offer = offer
        self.limits = limits
    }

    /// The trial product as an offer the paywall can buy. It grants the same
    /// plan as the plan's monthly product.
    public var billingOffer: BillingOffer {
        BillingOffer(planID: planID, product: product, billingPeriod: BillingPeriod(productID: product.id) ?? .monthly)
    }
}

/// Whether the paywall may show a free trial.
public enum BillingTrialState: Sendable, Equatable {
    /// The server offers none, or it was not checked yet.
    case none
    /// The device proof and server check are running.
    case checking
    /// The trial may be shown and bought.
    case available(BillingTrialGrant)
    /// The trial was refused or the proof failed; show no trial text.
    case unavailable(reason: String)

    /// The grant, when available.
    public var grant: BillingTrialGrant? {
        if case .available(let grant) = self { return grant }
        return nil
    }
}

/// The free-trial introductory offer StoreKit reports for a product.
public struct StoreIntroductoryOffer: Sendable, Equatable, Hashable {
    /// The unit of a trial period.
    public enum PeriodUnit: String, Sendable, Equatable, Hashable {
        case day, week, month, year
    }

    /// The number of units in one period, such as 7 for 7 days.
    public let periodValue: Int
    /// The unit of one period.
    public let periodUnit: PeriodUnit
    /// How many periods the offer lasts.
    public let periodCount: Int
    /// True for a free trial; pay-as-you-go and pay-up-front offers are
    /// false and are never shown as a trial.
    public let isFreeTrial: Bool
    /// Whether StoreKit says this Apple Account may still use the offer.
    public let isEligibleOnDevice: Bool

    /// Creates an offer.
    public init(periodValue: Int, periodUnit: PeriodUnit, periodCount: Int, isFreeTrial: Bool, isEligibleOnDevice: Bool) {
        self.periodValue = periodValue
        self.periodUnit = periodUnit
        self.periodCount = periodCount
        self.isFreeTrial = isFreeTrial
        self.isEligibleOnDevice = isEligibleOnDevice
    }

    /// The trial's full length as date components, such as 7 days.
    public var duration: DateComponents {
        let total = periodValue * max(periodCount, 1)
        switch periodUnit {
        case .day: return DateComponents(day: total)
        case .week: return DateComponents(day: total * 7)
        case .month: return DateComponents(month: total)
        case .year: return DateComponents(year: total)
        }
    }

    /// When a trial started at `start` ends and the first charge happens.
    public func endDate(from start: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: duration, to: start)
    }
}

/// One paywall variant the server has served, for the staff Paywall Lab.
public struct BillingPaywallVariant: Sendable, Equatable, Hashable, Identifiable {
    /// `live` or `retired`.
    public let status: String
    /// The configuration.
    public let config: BillingPaywallConfig

    /// A stable identity: experiment and variant.
    public var id: String { config.experiment + "/" + config.variant }

    /// Creates a variant.
    public init(status: String, config: BillingPaywallConfig) {
        self.status = status
        self.config = config
    }
}
