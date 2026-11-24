import CmuxNextHomeEngine
import Foundation
import Testing

/// The launch snapshot's file is discarded and rebuilt when the snapshot's shape changes
/// (linear-sync-engine reading note, row 4: "rebuild the cache on schema change"): no version to bump by hand.
@Suite struct HomeSidebarLaunchCacheSchemaTests {
    private static func cacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-home-schema-\(UUID().uuidString)/sidebar.json")
    }

    private static func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private static func snapshotJSON(_ snapshot: HomeSidebarLaunchSnapshot) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
    }

    @Test func aCacheWrittenUnderAnotherSchemaIsRejectedAndRebuilt() throws {
        let url = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = HomeSidebarLaunchSnapshot(account: "me", chiefHarnesses: ["main": "claude"], archivedChiefs: ["old"])
        try Self.write(["schema": "0000000000000000", "snapshot": Self.snapshotJSON(snapshot)], to: url)

        #expect(HomeSidebarLaunchCache(url: url).load(account: "me") == nil)

        let rebuilt = HomeSidebarLaunchCache(url: url)
        rebuilt.save(snapshot)
        rebuilt.flush()
        #expect(HomeSidebarLaunchCache(url: url).load(account: "me") == snapshot)
        let file = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(file["schema"] as? String == HomeSidebarLaunchSnapshot.schema)
    }

    @Test func theHandBumpedVersionFileIsRejected() throws {
        let url = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var legacy = try #require(Self.snapshotJSON(HomeSidebarLaunchSnapshot(account: "me")) as? [String: Any])
        legacy["version"] = 1
        try Self.write(legacy, to: url)
        #expect(HomeSidebarLaunchCache(url: url).load(account: "me") == nil)
    }

    @Test func theFingerprintFollowsTheStoredShape() {
        struct Before { var account = ""; var pins: [String] = [] }
        struct Added { var account = ""; var pins: [String] = []; var tags: [String]? }
        struct Retyped { var account = ""; var pins: Set<String> = [] }
        struct Renamed { var account = ""; var pinned: [String] = [] }
        let before = HomeSidebarLaunchCache.fingerprint(of: Before())
        #expect(before == HomeSidebarLaunchCache.fingerprint(of: Before(account: "other", pins: ["a"])))
        #expect(before.count == 16)
        for changed in [HomeSidebarLaunchCache.fingerprint(of: Added()), HomeSidebarLaunchCache.fingerprint(of: Retyped()),
                        HomeSidebarLaunchCache.fingerprint(of: Renamed())] {
            #expect(changed != before)
        }
        #expect(HomeSidebarLaunchSnapshot.schema == HomeSidebarLaunchCache.fingerprint(of: HomeSidebarLaunchSnapshot(account: "x")))
    }
}
