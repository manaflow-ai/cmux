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

    /// The Chiefs of a `chief.list` value that are not archived.
    public static func list(from value: Any?) -> [HomeChiefRecord] {
        ((value as? [String: Any])?["chiefs"] as? [[String: Any]] ?? []).compactMap(parse)
    }

    /// The agent ids of a `chief.list` value's archived and deleted Chiefs.
    public static func archivedIDs(from value: Any?) -> Set<String> {
        let list = (value as? [String: Any])?["chiefs"] as? [[String: Any]] ?? []
        // A deleted Chief, and one archived past its restore window, is only a tombstone.
        let tombstones = (value as? [String: Any])?["tombstones"] as? [[String: Any]] ?? []
        return Set(list.compactMap { $0["archived_at"] is String ? $0["id"] as? String : nil })
            .union(tombstones.compactMap { $0["id"] as? String })
    }

    /// One `HomeChief` value; nil when it has no id or is archived.
    public static func parse(_ value: Any?) -> HomeChiefRecord? {
        guard let object = value as? [String: Any], let id = object["id"] as? String,
              (object["archived_at"] as? String) == nil else { return nil }
        return HomeChiefRecord(id: id, name: object["display_name"] as? String ?? "", isDefault: object["is_default"] as? Bool ?? false,
                               rev: (object["rev"] as? NSNumber)?.intValue ?? 0, mainConversation: object["main_conversation"] as? String,
                               placed: object["brain_place"] is [String: Any])
    }
}

extension HomeCloudChiefs {
    /// The cloud Chief whose main conversation is `conversation`: its agent id and whether a
    /// paired server runs it, from the Chief tab's Chiefs, else from `records` (the directory's
    /// `chief.list`); nil while neither knows it.
    public func placement(of conversation: String, records: [HomeChiefRecord]) -> (id: String, placed: Bool)? {
        if let chief = chief(for: conversation) { return (chief.id, chief.brainPlace != nil) }
        return records.first { $0.mainConversation == conversation }.map { ($0.id, $0.placed) }
    }
}
