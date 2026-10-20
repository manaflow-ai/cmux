import CmuxNextSettings
import Testing

/// `sidebar.nowPlaying.enabled`: the Now Playing player shows unless the user hides it, Settings
/// lists the toggle, and a bad value keeps the player with a diagnostic. `tabs.newTabNowPlaying`
/// hides the New Tab page's player only, is on by default, and agents may set it like the other
/// New Tab keys.
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

    static func parseNewTab(_ value: JSONValue?, enabled: Bool? = nil) -> CmuxConfigSnapshot {
        var root: [String: JSONValue] = [:]
        if let value { root["tabs"] = .object(["newTabNowPlaying": value]) }
        if let enabled { root["sidebar"] = .object(["nowPlaying": .object(["enabled": .bool(enabled)])]) }
        return CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
    }

    @Test func theNewTabPlayerShowsByDefaultAndTheUserCanHideItThere() {
        let unset = Self.parseNewTab(nil)
        #expect(unset.nowPlaying.newTab && unset.nowPlaying.showsOnNewTab)
        #expect(unset.diagnostics.isEmpty, "\(unset.diagnostics)")
        let off = Self.parseNewTab(.bool(false))
        #expect(!off.nowPlaying.newTab && !off.nowPlaying.showsOnNewTab)
        #expect(off.nowPlaying.enabled, "hiding the New Tab player hid the sidebar card")
        #expect(!Self.parseNewTab(.bool(true), enabled: false).nowPlaying.showsOnNewTab, "Show Now Playing off left the New Tab player")
    }

    @Test func aBadNewTabValueKeepsThePlayerAndSaysWhy() {
        let snapshot = Self.parseNewTab(.string("off"))
        #expect(snapshot.nowPlaying.newTab)
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.newTabNowPlaying" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheNewTabToggleOnByDefaultWithTheOtherNewTabRows() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabNowPlaying"]))
        #expect(descriptor.defaultValue == .bool(true))
        let template = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabTemplate"]))
        #expect(descriptor.section == template.section && descriptor.group == template.group, "not with the New Tab rows")
        #expect(SettingsSchema.agentSettableKeys.contains("tabs.newTabNowPlaying"), "agents cannot set it like tabs.newTabTemplate")
    }
}
