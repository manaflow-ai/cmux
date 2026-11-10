import Foundation

/// Who a device's connectivity events are recorded for, from the signed-in account's email.
///
/// The cmux team (an account whose email domain is `manaflow.ai` or `cmux.com`, or a subdomain
/// of one) gets ``team``: every event, its free-text detail (error text, endpoints, peer ids) and
/// no sampling. Everyone else, and a signed-out device, gets ``everyone``: fixed-vocabulary
/// fields only, sampled and budgeted (``ConnectivityPolicy``).
public enum ConnectivityAudience: String, Sendable, Equatable, Codable, CaseIterable {
    case team
    case everyone

    /// The email domains of the cmux team.
    public static let teamDomains: [String] = ["manaflow.ai", "cmux.com"]

    /// The audience of a signed-in account.
    ///
    /// Matches the domain after the last `@`, trimmed and lowercased, exactly or as a subdomain
    /// (`eng.manaflow.ai`); a domain that only ends in the same letters (`notmanaflow.ai`) or
    /// carries it as a prefix (`manaflow.ai.example.com`) is ``everyone``.
    /// - Parameter email: The account's primary email, or nil when signed out.
    public init(email: String?) {
        guard let email,
              let at = email.lastIndex(of: "@")
        else {
            self = .everyone
            return
        }
        let local = email[..<at].trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = email[email.index(after: at)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isTeam = !local.isEmpty && Self.teamDomains.contains { team in
            domain == team || domain.hasSuffix("." + team)
        }
        self = isTeam ? .team : .everyone
    }

    /// Whether this audience records free-text detail and every event.
    public var isVerbose: Bool { self == .team }
}
