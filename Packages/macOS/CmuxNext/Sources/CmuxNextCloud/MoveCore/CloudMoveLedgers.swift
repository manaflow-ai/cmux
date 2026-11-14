public import Foundation

/// What Retry does for a chat whose Move to Cloud or Bring Back Local stopped, by the chat's daemon tab. Kept
/// in the user defaults `CloudMoveSetup.ledger` names under `key` (in memory without them), so a quit or a crash
/// mid-move keeps it. Rust reads the ledger leniently and changes it (`moves::ledger`, op `cloud_move_retries`);
/// its JSON is the one this type's `Codable` wrote before.
@MainActor
public final class CloudMoveRetries {
    /// What Retry does for one chat.
    public enum Retry: Codable, Equatable, Sendable {
        /// The chat may not have moved: run the move again, to this machine.
        case move(machineID: String)
        /// The chat moved: only open its tab on the machine.
        case show(Shown)
        /// Bring Back Local only: run the move again, narrowing the chat to an asking policy and mode first.
        case askFirst(machineID: String)
        /// The machine's cmux-tui is too old for the move: "Update Machine", then the move again.
        case update(machineID: String)
    }

    /// A moved chat whose tab on the machine didn't open yet.
    public struct Shown: Codable, Equatable, Sendable {
        public var session: String
        public var harness: String?
        public var machineID: String
        /// The chat's folder on the machine (the terminal's too).
        public var folder: String
        /// The workspace name the chat had on this Mac.
        public var name: String?
        /// The move's id: makes the tab's creation idempotent.
        public var key: String
        /// For a chat Bring Back Local moved here: its ledger entry's machine tab host and session.
        public var host: String?
        public var movedSession: String?

        public init(session: String, harness: String?, machineID: String, folder: String, name: String?, key: String,
                    host: String? = nil, movedSession: String? = nil) {
            (self.session, self.harness, self.machineID, self.folder, self.name) = (session, harness, machineID, folder, name)
            (self.key, self.host, self.movedSession) = (key, host, movedSession)
        }
    }

    /// The defaults key: one per kind of move.
    public let key: String
    /// Where the retries are kept (`CloudMoveSetup.ledger`); nil keeps them in memory.
    public var defaults: @MainActor () -> UserDefaults? = { nil }
    private var memory: String?

    public init(key: String) {
        self.key = key
    }

    private struct Request: Encodable {
        var stored: String?
        var tab = "", set = false
        var retry: Retry?
    }
    private struct Reply: Decodable { var retries: [String: Retry]?, changed: Bool?, stored: String? }

    private var stored: String? {
        guard let defaults = defaults() else { return memory }
        return defaults.data(forKey: key).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The retry for the chat in daemon tab `tab`; nil clears it.
    public subscript(tab: String) -> Retry? {
        get { entries()[tab] }
        set {
            guard let reply = CloudMoveCore().call("retries", Request(stored: stored, tab: tab, set: true, retry: newValue), as: Reply.self),
                  reply.changed == true else { return }
            guard let defaults = defaults() else { return memory = reply.stored }
            if let value = reply.stored { defaults.set(Data(value.utf8), forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    /// The tabs with a retry, in a stable order.
    public var tabs: [String] { entries().keys.sorted() }

    private func entries() -> [String: Retry] {
        CloudMoveCore().call("retries", Request(stored: stored), as: Reply.self)?.retries ?? [:]
    }
}

extension CloudMoveRetries.Retry {
    /// The machine a rerun goes to; none for a move that committed.
    public var machineID: String? {
        switch self {
        case .move(let machineID), .askFirst(let machineID), .update(let machineID): machineID
        case .show: nil
        }
    }

    /// This Retry for a machine whose cmux-tui is too old: "Update Machine" on its machine.
    public var updating: Self { machineID.map { .update(machineID: $0) } ?? self }
}

/// An agent's persistent "Always move to Cloud" approval: a grant belongs to the signed-in user, selected team,
/// Cloud API origin and canonical sync folder. Rust keeps the rules (`moves::ledger`, op `cloud_move_grants`),
/// including never reading the old folder-only `cmux.cloud.moveAlwaysFolders`.
public struct CloudMoveAlwaysGrants {
    public struct Scope: Hashable {
        public let userID: String
        public let teamID: String
        public let cloudOrigin: String

        /// Nil unless the user, the team and the origin are each there.
        public init?(userID: String?, teamID: String?, cloudOrigin: String) {
            struct Reply: Decodable { var valid: Bool }
            let request = Request(action: "scope", userID: userID, teamID: teamID, cloudOrigin: cloudOrigin)
            guard CloudMoveCore().call("grants", request, as: Reply.self)?.valid == true, let userID, let teamID else { return nil }
            self.userID = userID
            self.teamID = teamID
            self.cloudOrigin = cloudOrigin
        }
    }

    /// One stored grant. Public for the App's `DebugCloudMove` read and seed only.
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

    fileprivate struct Request: Encodable {
        var stored: String?, action: String, userID: String?, teamID: String?, cloudOrigin: String, folder: String, always: Bool, grants: [Grant]
        init(stored: String? = nil, action: String, userID: String? = nil, teamID: String? = nil, cloudOrigin: String = "", folder: String = "",
             always: Bool = false, grants: [Grant] = []) {
            (self.stored, self.action, self.userID, self.teamID, self.cloudOrigin) = (stored, action, userID, teamID, cloudOrigin)
            (self.folder, self.always, self.grants) = (folder, always, grants)
        }

        init(_ action: String, _ scope: Scope, folder: String, stored: String?, always: Bool = false) {
            self.init(stored: stored, action: action, userID: scope.userID, teamID: scope.teamID, cloudOrigin: scope.cloudOrigin,
                      folder: folder, always: always)
        }
    }

    public static let defaultsKey = "cmux.cloud.moveAlwaysGrants.v2"
    private var memory: String?

    public init() {}

    private func stored(_ defaults: UserDefaults?) -> String? {
        guard let defaults else { return memory }
        return defaults.data(forKey: Self.defaultsKey).map { String(decoding: $0, as: UTF8.self) }
    }

    public func contains(_ folder: String, scope: Scope?, defaults: UserDefaults?) -> Bool {
        struct Reply: Decodable { var granted: Bool }
        guard let scope else { return false }
        return CloudMoveCore().call("grants", Request("contains", scope, folder: folder, stored: stored(defaults)), as: Reply.self)?.granted ?? false
    }

    public mutating func remember(_ folder: String, scope: Scope?, always: Bool, defaults: UserDefaults?) {
        struct Reply: Decodable { var stored: String? }
        guard let scope,
              let value = CloudMoveCore().call("grants", Request("remember", scope, folder: folder, stored: stored(defaults), always: always),
                                               as: Reply.self)?.stored else { return }
        guard let defaults else { return memory = value }
        defaults.set(Data(value.utf8), forKey: Self.defaultsKey)
    }

    /// Every grant kept in `defaults`; a missing or damaged preference reads as none.
    public static func stored(in defaults: UserDefaults) -> [Grant] {
        struct Reply: Decodable { var grants: [Grant] }
        let stored = defaults.data(forKey: defaultsKey).map { String(decoding: $0, as: UTF8.self) }
        return CloudMoveCore().call("grants", Request(stored: stored, action: "list"), as: Reply.self)?.grants ?? []
    }

    /// Replaces the grants kept in `defaults`, in a stable order.
    public static func store(_ entries: [Grant], in defaults: UserDefaults) {
        struct Reply: Decodable { var stored: String }
        guard let value = CloudMoveCore().call("grants", Request(action: "store", grants: entries), as: Reply.self)?.stored else { return }
        defaults.set(Data(value.utf8), forKey: defaultsKey)
    }
}
