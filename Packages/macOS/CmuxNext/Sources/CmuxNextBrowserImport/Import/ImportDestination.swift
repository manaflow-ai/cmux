import Foundation

/// Creates cmux browser profiles (data-model.md 5). The caller picks the id
/// so a retry finds the same record; returns the profile id to import into.
/// Until browser profile records exist, the App passes `DefaultProfileOnly`.
/// `look` is the source profile's own color and picture, so the new
/// profile looks like the one it came from; an existing id keeps its look.
public protocol BrowserProfileProvisioning: Sendable {
    func createProfile(id: String, name: String, look: SourceProfileLook, source: [String: String]) async throws -> String
}

/// How a source profile looks in its browser: its color (0xRRGGBB) and
/// account picture, when it has them.
public struct SourceProfileLook: Sendable, Equatable {
    public var color: UInt32?
    public var avatar: URL?

    public init(color: UInt32? = nil, avatar: URL? = nil) {
        self.color = color
        self.avatar = avatar
    }

    public init(_ profile: BrowserSourceProfile) {
        self.init(color: profile.color, avatar: profile.avatar)
    }
}

/// Keeps every import in the default browser profile; the mapping still
/// records each source's proposed profile id so it can be split later.
public struct DefaultProfileOnly: BrowserProfileProvisioning {
    public init() {}
    public func createProfile(id: String, name: String, look: SourceProfileLook, source: [String: String]) async throws -> String {
        "default"
    }
}

/// Receives each source profile's data after it is read. The App saves it
/// (``ImportedDataStore``) and feeds the live browser (omnibar history).
public protocol ImportDestination: Sendable {
    func commit(_ batch: ImportBatch) async throws
}
