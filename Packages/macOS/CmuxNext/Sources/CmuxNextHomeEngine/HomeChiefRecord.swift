import Foundation

/// One of the user's Chiefs, as UserDO's `chief.list` reports it (Home's
/// New Chief and archive read these; ``CloudChief`` is the Chief tab's view).
public nonisolated struct HomeChiefRecord: Hashable, Sendable {
    public var id: String
    public var name: String
    public var isDefault: Bool
    public var rev: Int
    public var mainConversation: String?
    /// A paired server runs it (`brain_place`); false: the Cloud service's brain does.
    public var placed: Bool

    /// - Parameters:
    ///   - id: The Chief's agent id.
    ///   - name: Its display name.
    ///   - isDefault: It is the user's default Chief.
    ///   - rev: The record's revision.
    ///   - mainConversation: Its main conversation, when it has one.
    ///   - placed: A paired server runs its brain.
    public init(id: String, name: String, isDefault: Bool, rev: Int, mainConversation: String?, placed: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.rev = rev
        self.mainConversation = mainConversation
        self.placed = placed
    }

    /// The Chiefs of a `chief.list` value that are not archived (Rust `chief_home.record_list`).
    public static func list(from value: Any?) -> [HomeChiefRecord] {
        struct Reply: Decodable { let chiefs: [Wire] }
        return ((try? ChiefHomeRules().call("record_list", value: value)) as Reply?)?.chiefs.map(\.record) ?? []
    }

    /// The agent ids of a `chief.list` value's archived and deleted Chiefs (Rust `chief_home.archived_ids`).
    public static func archivedIDs(from value: Any?) -> Set<String> {
        struct Reply: Decodable { let ids: [String] }
        return Set(((try? ChiefHomeRules().call("archived_ids", value: value)) as Reply?)?.ids ?? [])
    }

    /// One `HomeChief` value; nil when it has no id or is archived.
    public static func parse(_ value: Any?) -> HomeChiefRecord? {
        list(from: ["chiefs": [value ?? NSNull()]]).first
    }

    /// A record as Rust replies it.
    private struct Wire: Decodable {
        let id: String
        let name: String
        let isDefault: Bool
        let rev: Int
        let mainConversation: String?
        let placed: Bool

        var record: HomeChiefRecord {
            HomeChiefRecord(id: id, name: name, isDefault: isDefault, rev: rev, mainConversation: mainConversation, placed: placed)
        }
    }
}
