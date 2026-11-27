/// Sites that send verification codes for another site of the same owner
/// (plans/cmux-next/email-verification-autofill/DESIGN.md "Matching", rule 4): a code from
/// `accountprotection.microsoft.com` may fill `login.live.com`, one from `tm.openai.com` may fill
/// `chatgpt.com`. Each group is a set of exact registrable domains one company owns; a
/// lookalike (`microsoft.com.evil.io`) is its own registrable domain and is in no group. Only
/// codes use the map: a link must stay on the page's own site.
///
/// ```swift
/// VerificationSenderMap.reviewed.sameOwner("openai.com", "chatgpt.com") // true
/// ```
public nonisolated struct VerificationSenderMap: Sendable {
    private let owner: [String: Int]

    /// - Parameter groups: Sets of registrable domains, each owned by one company.
    public init(groups: [Set<String>]) {
        var owner: [String: Int] = [:]
        for (index, group) in groups.enumerated() {
            for domain in group { owner[domain.lowercased()] = index }
        }
        self.owner = owner
    }

    /// True when `first` and `second` are the same registrable domain or in the same group.
    /// - Parameters:
    ///   - first: A registrable domain.
    ///   - second: Another registrable domain.
    public func sameOwner(_ first: String, _ second: String) -> Bool {
        let a = first.lowercased(), b = second.lowercased()
        if a == b { return true }
        guard let groupA = owner[a], let groupB = owner[b] else { return false }
        return groupA == groupB
    }

    /// The reviewed groups: each domain checked to belong to the named company. Add a group only
    /// after checking every domain's owner (WHOIS, the company's own sign-in pages).
    public static let reviewed = VerificationSenderMap(groups: [
        // Microsoft account and Entra sign-in.
        ["microsoft.com", "live.com", "microsoftonline.com", "outlook.com", "office.com", "xbox.com", "skype.com"],
        // Google account, YouTube.
        ["google.com", "youtube.com"],
        // Meta: Facebook mails from facebookmail.com.
        ["facebook.com", "facebookmail.com", "meta.com"],
        // OpenAI: ChatGPT sign-in codes come from openai.com.
        ["openai.com", "chatgpt.com"],
        // Anthropic: Claude sign-in.
        ["anthropic.com", "claude.ai", "claude.com"],
        // X, formerly Twitter.
        ["x.com", "twitter.com"],
        // Valve: Steam store and community.
        ["steampowered.com", "steamcommunity.com"],
        // Apple account and iCloud.
        ["apple.com", "icloud.com"],
    ])
}
