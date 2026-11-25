import Foundation

/// A member of a team as Settings lists it (Stack `team-member-profiles`).
public struct TeamMember: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isYou: Bool

    public init(id: String, name: String, isYou: Bool) {
        self.id = id
        self.name = name
        self.isYou = isYou
    }

    public var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// Profiles as Stack returns them: you first, then by name. A profile
    /// with no display name shows as "Team member" (yours as your own name).
    public static func list(_ profiles: [(userID: String, displayName: String?)], you: (id: String, name: String)) -> [TeamMember] {
        var members = profiles.filter { !$0.userID.isEmpty }.map { profile in
            let isYou = profile.userID == you.id
            let name = profile.displayName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            return TeamMember(id: profile.userID, name: name ?? (isYou ? you.name : "Team member"), isYou: isYou)
        }
        if !members.contains(where: \.isYou) { members.append(TeamMember(id: you.id, name: you.name, isYou: true)) }
        return members.sorted { lhs, rhs in
            lhs.isYou != rhs.isYou ? lhs.isYou : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// A way the signed-in account can sign in (Stack's current user).
public enum SignInMethod: Hashable, Sendable, Identifiable {
    case apple
    case google
    case github
    /// Another OAuth provider, by its Stack id.
    case oauth(String)
    /// A one-time code sent to this address.
    case emailCode(String)
    case password
    case passkey

    public var id: String { title }

    public var title: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        case .github: "GitHub"
        case .oauth(let provider): provider.prefix(1).uppercased() + provider.dropFirst()
        case .emailCode: "Email code"
        case .password: "Password"
        case .passkey: "Passkey"
        }
    }

    public var detail: String? {
        if case .emailCode(let email) = self { return email }
        return nil
    }

    /// The detail Settings → Account shows next to the method: the code's
    /// address only when it differs from the account's own email (shown
    /// once, in the header).
    public func detail(accountEmail: String?) -> String? {
        guard let detail else { return nil }
        if let accountEmail, detail.caseInsensitiveCompare(accountEmail) == .orderedSame { return nil }
        return detail
    }

    /// The methods for a Stack user: OAuth providers (deduplicated, in Stack's
    /// order), then email code, password and passkey when enabled.
    public static func methods(oauthProviderIDs: [String], otpEmail: String?, hasPassword: Bool, hasPasskey: Bool) -> [SignInMethod] {
        var methods: [SignInMethod] = []
        for id in oauthProviderIDs where !id.isEmpty {
            let method: SignInMethod = switch id.lowercased() {
            case "apple": .apple
            case "google": .google
            case "github": .github
            default: .oauth(id)
            }
            if !methods.contains(method) { methods.append(method) }
        }
        if let otpEmail, !otpEmail.isEmpty { methods.append(.emailCode(otpEmail)) }
        if hasPassword { methods.append(.password) }
        if hasPasskey { methods.append(.passkey) }
        return methods
    }
}
