public import Foundation

/// Facts the approving device shows before Approve (section 6.2 step 3):
/// everything the pending pairing knows about the server, and the teams the
/// approver may enroll it into.
public nonisolated struct PairingCandidate: Sendable, Equatable {
    public var code: String
    public var name: String
    public var os: String
    public var version: String
    /// ISO 3166 region code from the begin request (coarse location).
    public var region: String?
    public var words: [String]
    public var teams: [ServerTeam]
    /// The server runs a Chief brain (`optchat-chief cloud pair`): the
    /// approver offers to run the user's Chief there.
    public var isChiefBrain: Bool

    public init(code: String, name: String, os: String, version: String, region: String?, words: [String], teams: [ServerTeam],
                isChiefBrain: Bool = false) {
        self.code = code
        self.name = name
        self.os = os
        self.version = version
        self.region = region
        self.words = words
        self.teams = teams
        self.isChiefBrain = isChiefBrain
    }
}

public nonisolated struct ServerTeam: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
