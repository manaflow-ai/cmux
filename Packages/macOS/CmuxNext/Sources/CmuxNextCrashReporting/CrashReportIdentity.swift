public import Foundation

/// Who and what a cmux-next crash or hang report comes from, as Sentry tags
/// (``CrashEventLabels``): this Mac's anonymous install id, the build's commit,
/// and, only for a member of the cmux team itself, that person's name.
///
/// Everyone else stays anonymous: the install id is a random UUID made on the
/// first launch, kept in the app's own defaults, and tells one Mac's reports
/// apart from another's without saying whose Mac it is. The team's own
/// dogfood builds name the person, so the team sees whose hangs arrive.
///
/// ```swift
/// let identity = CrashReportIdentity(installID: CrashReportIdentity.installID(in: .standard),
///                                    commit: Bundle.main.infoDictionary?["CMUXCommit"] as? String)
/// ```
public nonisolated struct CrashReportIdentity: Sendable, Equatable {
    /// The `UserDefaults` key of this Mac's anonymous install id.
    public static let installIDKey = "cmux.next.crashReporting.installID"
    /// The cmux Cloud team whose members' reports carry their name: the
    /// team "cmux" (the people who build cmux).
    public static let cmuxTeamID = "d13acd51-c77d-438a-9610-5369455e2a2f"

    /// This Mac's anonymous install id (a UUID string); nil sends no `install` tag.
    public var installID: String?
    /// The build's commit (`CMUXCommit` in Info.plist); nil when the build has none.
    public var commit: String?
    /// The signed-in member of the cmux team, or nil (anyone else, or signed out).
    public var member: CrashTeamMember?

    /// - Parameters:
    ///   - installID: This Mac's anonymous install id.
    ///   - commit: The build's commit.
    ///   - member: The signed-in cmux team member, if any.
    public init(installID: String? = nil, commit: String? = nil, member: CrashTeamMember? = nil) {
        self.installID = installID
        self.commit = commit
        self.member = member
    }

    /// This launch's identity: the install id in `defaults` (made on the first
    /// launch) and the commit in the bundle's `info` (`CMUXCommit`); no member yet.
    /// - Parameters:
    ///   - defaults: The app's own defaults.
    ///   - info: The bundle's Info.plist dictionary.
    public init(defaults: UserDefaults, info: [String: Any]) {
        self.init(installID: Self.installID(in: defaults), commit: info["CMUXCommit"] as? String)
    }

    /// The tags these values add to every event: `install`, `commit`, and for a
    /// team member `reporter` (the name) and `reporter_id` (the cmux account id).
    public var tags: [String: String] {
        var tags: [String: String] = [:]
        if let installID, !installID.isEmpty { tags["install"] = installID }
        if let commit, !commit.isEmpty { tags["commit"] = String(commit.prefix(12)) }
        if let member {
            tags["reporter"] = member.name
            tags["reporter_id"] = member.id
        }
        return tags
    }

    /// This Mac's install id in `defaults`, made and stored on the first call.
    /// - Parameter defaults: The app's own defaults.
    /// - Returns: A UUID string, the same on every later call.
    public static func installID(in defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: installIDKey), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: installIDKey)
        return id
    }

    /// The team member a signed-in account is, or nil when it is not in
    /// `teamID` (or nobody is signed in).
    /// - Parameters:
    ///   - userID: The signed-in cmux account id.
    ///   - name: The account's display name.
    ///   - email: The account's email: its local part names a member with no display name.
    ///   - teamIDs: The ids of the teams the account is in.
    ///   - teamID: The team whose members are named (``cmuxTeamID``).
    /// - Returns: The member, or nil.
    public static func member(userID: String?, name: String?, email: String?, teamIDs: [String],
                              teamID: String = cmuxTeamID) -> CrashTeamMember? {
        guard let userID, !userID.isEmpty, teamIDs.contains(teamID) else { return nil }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let local = email.flatMap { $0.split(separator: "@").first.map(String.init) } ?? ""
        let shown = !trimmed.isEmpty ? trimmed : !local.isEmpty ? local : userID
        return CrashTeamMember(id: userID, name: shown)
    }
}
