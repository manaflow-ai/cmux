public import Foundation

/// In-memory persistence for tests and demos.
public actor MemorySitePermissionPersistence: SitePermissionPersistence {
    public private(set) var saved: SitePermissionSnapshot
    public private(set) var saveCount = 0

    public init(_ snapshot: SitePermissionSnapshot = SitePermissionSnapshot()) {
        saved = snapshot
    }

    public func load() async -> SitePermissionSnapshot { saved }

    public func save(_ snapshot: SitePermissionSnapshot) async {
        saved = snapshot
        saveCount += 1
    }
}
