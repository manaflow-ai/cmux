public import Foundation

/// An agent's persistent "Always move to Cloud" approval. A grant belongs to the
/// signed-in user, selected team, Cloud API origin and canonical sync folder.
/// A different account, team, backend or folder must ask the person again.
///
/// The old "cmux.cloud.moveAlwaysFolders" array contains only paths. Deliberately
/// do not read or migrate it: the account and team that approved those paths
/// cannot be recovered, so migration would silently restore ambiguous authority.
public struct CloudMoveAlwaysGrants {
    public struct Scope: Hashable {
        public let userID: String
        public let teamID: String
        public let cloudOrigin: String

        public init?(userID: String?, teamID: String?, cloudOrigin: String) {
            guard let userID, !userID.isEmpty, let teamID, !teamID.isEmpty, !cloudOrigin.isEmpty else { return nil }
            self.userID = userID
            self.teamID = teamID
            self.cloudOrigin = cloudOrigin
        }
    }

    /// One stored grant. Public for the App's ``DebugCloudMove`` read and seed only.
    public struct Grant: Codable, Hashable {
        public let userID: String
        public let teamID: String
        public let cloudOrigin: String
        public let folder: String

        public init(scope: Scope, folder: String) {
            userID = scope.userID
            teamID = scope.teamID
            cloudOrigin = scope.cloudOrigin
            self.folder = folder
        }
    }

    public static let defaultsKey = "cmux.cloud.moveAlwaysGrants.v2"
    private var memory: Set<Grant> = []

    public init() {}

    public func contains(_ folder: String, scope: Scope?, defaults: UserDefaults?) -> Bool {
        guard let scope else { return false }
        return grants(in: defaults).contains(Grant(scope: scope, folder: folder))
    }

    public mutating func remember(_ folder: String, scope: Scope?, always: Bool, defaults: UserDefaults?) {
        guard let scope else { return }
        let grant = Grant(scope: scope, folder: folder)
        var entries = grants(in: defaults)
        if always { entries.insert(grant) } else { entries.remove(grant) }
        guard let defaults else {
            memory = entries
            return
        }
        Self.store(Array(entries), in: defaults)
    }

    /// Every grant kept in `defaults`; a missing or damaged preference reads as none.
    public static func stored(in defaults: UserDefaults) -> [Grant] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([Grant].self, from: data) else { return [] }
        return entries
    }

    /// Replaces the grants kept in `defaults`, in a stable order.
    public static func store(_ entries: [Grant], in defaults: UserDefaults) {
        let sorted = Set(entries).sorted { ($0.userID, $0.teamID, $0.cloudOrigin, $0.folder) <
            ($1.userID, $1.teamID, $1.cloudOrigin, $1.folder) }
        if let data = try? JSONEncoder().encode(sorted) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private func grants(in defaults: UserDefaults?) -> Set<Grant> {
        guard let defaults else { return memory }
        return Set(Self.stored(in: defaults))
    }
}
