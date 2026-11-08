public import Foundation

/// A fork of this home's Chief in cmux Cloud, as `state/fork.json` says (optchat-chief
/// migrate_fork.rs `Fork`): a new hosted Chief with a copy of this Chief's memory, while this
/// home keeps answering. The Mac Chief reaches it with `tell("chief:fork", …)`.
public nonisolated struct ChiefForkRecord: Equatable, Sendable {
    /// The fork's name ("Chief fork" unless the move named it).
    public var name: String
    /// The hosted Chief's agent id.
    public var chief: String
    /// When the fork was made; nil when the file's date does not parse.
    public var at: Date?

    public init(name: String, chief: String, at: Date?) {
        self.name = name
        self.chief = chief
        self.at = at
    }

    /// The fork a `fork.json` names; nil for no file or one that is not the engine's record.
    ///
    /// - Parameter json: The file's bytes.
    public init?(json: Data?) {
        guard let json, let file = try? JSONDecoder().decode(File.self, from: json), !file.chief.isEmpty else { return nil }
        name = file.name
        chief = file.chief
        at = file.at.flatMap { Date(chiefRFC3339: $0) }
    }

    private struct File: Decodable {
        var name: String
        var chief: String
        var at: String?
    }
}
