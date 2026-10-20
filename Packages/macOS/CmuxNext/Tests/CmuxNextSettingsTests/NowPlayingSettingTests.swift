import CmuxNextSettings
import Testing

/// `sidebar.nowPlaying.enabled`: the Now Playing player is hidden unless the user turns it on,
/// Settings lists the toggle, and a bad value keeps it hidden with a diagnostic.
struct NowPlayingSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["nowPlaying": .object(["enabled": $0])])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func hiddenByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.nowPlaying.enabled == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOnAndOff() {
        #expect(Self.parse(.bool(false)).nowPlaying.enabled == false)
        #expect(Self.parse(.bool(true)).nowPlaying.enabled)
    }

    @Test func aBadValueKeepsThePlayerHiddenAndSaysWhy() {
        let snapshot = Self.parse(.string("on"))
        #expect(snapshot.nowPlaying.enabled == false)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.nowPlaying.enabled" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "nowPlaying", "enabled"]))
        #expect(descriptor.defaultValue == .bool(false))
    }
}
