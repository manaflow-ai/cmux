import Foundation

/// `cloud-spare-warm` (`cloud-spare-warm-v1`, cmux-tui-core `server/cloud_spare_warm.rs`): the app's Cloud intent, one
/// daemon command. The daemon decides whether to warm, makes the warm or claim call and copies the person's Claude login
/// onto the machine, all in Rust; the app only sends what it holds (the tokens) and keeps (its defaults and cmux.json).
/// The reply is Rust's ledger answer, sent once the ledger is written; the copy runs on in the daemon after it.
public struct CloudSpareWarmRequest: DaemonRequest, CustomStringConvertible {
    public typealias Response = JSONValue
    public static let command = "cloud-spare-warm"
    public static let requiredCapability: String? = DaemonCapability.cloudSpareWarm.rawValue

    public let platform: String
    public let api: String
    public let accessToken: String
    public let installToken: String
    public let account: String
    public let claimed: String?
    public let team: String?
    /// The person's teams; Rust reads the selected team, these, then the personal login.
    public let loginTeams: [String]
    public let dogfood: Bool
    public let setting: Bool?
    public let storedChoice: String?
    public let consent: Bool?

    enum CodingKeys: String, CodingKey {
        case platform, api, accessToken, installToken, account, claimed, team, loginTeams, dogfood, setting, storedChoice, consent
    }

    public var description: String { "CloudSpareWarmRequest([redacted], claimed: \(claimed ?? "-"))" }

    public init(platform: String, api: String, accessToken: String, installToken: String, account: String, claimed: String?,
                team: String?, loginTeams: [String], dogfood: Bool, setting: Bool?, storedChoice: String?, consent: Bool?) {
        (self.platform, self.api, self.accessToken, self.installToken, self.account) = (platform, api, accessToken, installToken, account)
        (self.claimed, self.team, self.loginTeams, self.dogfood) = (claimed, team, loginTeams, dogfood)
        (self.setting, self.storedChoice, self.consent) = (setting, storedChoice, consent)
    }
}

/// `cloud-spare-warm-consent` (`cloud-spare-warm-v1`): the person's one-time Release consent, sent at once and on every
/// change, so a login copy in flight reads it right before its write and a change ends it.
public struct CloudSpareWarmConsentRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "cloud-spare-warm-consent"
    public static let requiredCapability: String? = DaemonCapability.cloudSpareWarm.rawValue

    public let consent: Bool?
    /// This read's number, taken when the consent was read (a later read has a larger one): the daemon keeps only a read
    /// newer than the last it took on this connection, so a stale send that arrives late never overwrites a newer one.
    public let generation: UInt64

    public init(consent: Bool?, generation: UInt64) { (self.consent, self.generation) = (consent, generation) }
}
