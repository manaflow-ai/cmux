import CmuxNextSettings
import Testing

/// `sidebar.nowPlaying.enabled`: the Now Playing player shows unless the user hides it, Settings
/// lists the toggle, and a bad value keeps the player with a diagnostic.
struct NowPlayingSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["nowPlaying": .object(["enabled": $0])])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func showsByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.nowPlaying.enabled)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanHideIt() {
        #expect(Self.parse(.bool(false)).nowPlaying.enabled == false)
        #expect(Self.parse(.bool(true)).nowPlaying.enabled)
    }

    @Test func aBadValueKeepsThePlayerAndSaysWhy() {
        let snapshot = Self.parse(.string("off"))
        #expect(snapshot.nowPlaying.enabled)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.nowPlaying.enabled" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOnByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "nowPlaying", "enabled"]))
        #expect(descriptor.defaultValue == .bool(true))
    }
}
