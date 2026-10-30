import Foundation


/// One validated team invite request from a run's arguments (`--email`,
/// `--team`, `--role`, `--reason`), before any team is looked up.
public nonisolated struct TeamInviteInput: Sendable, Equatable {
    /// The most addresses one invite request may name (cmux.com's own limit).
    public static let maxEmails = 20

    /// The addresses, trimmed, lowercased and without repeats.
    public var emails: [String]
    /// The team as the caller named it (id or name), nil for the default team.
    public var team: String?
    /// The role each invite grants.
    public var role: TeamInviteRole
    /// The caller's reason, empty when none.
    public var reason: String

    /// Validates a run's arguments.
    ///
    /// - Parameters:
    ///   - email: One or more addresses, separated by commas or spaces.
    ///   - team: A team id or name; nil or empty picks the default team.
    ///   - role: `member` (default) or `admin`.
    ///   - reason: Why the caller invites, shown on the confirmation.
    /// - Throws: ``TeamInviteRefusal`` for a missing or malformed address, too many addresses, or an unknown role.
    public init(email: String?, team: String? = nil, role: String? = nil, reason: String? = nil) throws {
        let words = (email ?? "").split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { throw TeamInviteRefusal(code: "invalid_params", message: TeamInviteStrings.missingEmail) }
        var seen = Set<String>()
        var emails: [String] = []
        for word in words {
            guard isEmailAddress(word) else { throw TeamInviteRefusal(code: "invalid_params", message: TeamInviteStrings.badEmail(word)) }
            if seen.insert(word).inserted { emails.append(word) }
        }
        guard emails.count <= Self.maxEmails else {
            throw TeamInviteRefusal(code: "invalid_params", message: TeamInviteStrings.tooManyEmails(Self.maxEmails))
        }
        let roleWord = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard let parsedRole = roleWord.isEmpty ? .member : TeamInviteRole(rawValue: roleWord) else {
            throw TeamInviteRefusal(code: "invalid_params", message: TeamInviteStrings.badRole(roleWord))
        }
        let teamWord = team?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.emails = emails
        self.team = teamWord.isEmpty ? nil : teamWord
        self.role = parsedRole
        self.reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// One `local@domain.tld` address with no spaces: the shape cmux.com accepts.
private nonisolated func isEmailAddress(_ text: String) -> Bool {
    let parts = text.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, parts[1].count >= 3 else { return false }
    let domain = parts[1]
    guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
    return !text.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" })
}
