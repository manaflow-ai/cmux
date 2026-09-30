public import Foundation

/// Browser profiles that keep nothing on disk (incognito windows). Stub:
/// the behavior lands in the next commit.
public final class OffTheRecordProfiles {
    public static let shared = OffTheRecordProfiles()
    public private(set) var active: Set<BrowserProfileID> = []

    public init() {}

    public func begin() -> BrowserProfileID { BrowserProfileID(rawValue: UUID()) }
    public func contains(_ profile: BrowserProfileID) -> Bool { false }
    public func isOffTheRecord(_ profile: BrowserProfileID) -> Bool { false }
    public func end(_ profile: BrowserProfileID) {}
    public func observeEnd(_ observer: @escaping (BrowserProfileID) -> Void) {}
}
