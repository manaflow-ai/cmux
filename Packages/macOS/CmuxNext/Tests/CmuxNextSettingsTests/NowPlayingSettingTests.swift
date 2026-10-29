import CmuxNextSettings
import Testing

/// `sidebar.nowPlaying.enabled`: the Now Playing player is hidden unless the user turns it on,
/// Settings lists the toggle, and a bad value keeps it hidden with a diagnostic.
/// `tabs.newTabNowPlaying`: the New Tab page's player, off by default (u8394) and apart from the
/// sidebar card; the user can turn it on or hide it, and agents may set it like the other New Tab keys.
/// `sidebar.nowPlaying.otherApps`: other apps (another browser) feed the players only when on.
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

    static func parseNewTab(_ value: JSONValue?, enabled: Bool? = nil) -> CmuxConfigSnapshot {
        var root: [String: JSONValue] = [:]
        if let value { root["tabs"] = .object(["newTabNowPlaying": value]) }
        if let enabled { root["sidebar"] = .object(["nowPlaying": .object(["enabled": .bool(enabled)])]) }
        return CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
    }

    @Test func theNewTabPlayerIsHiddenByDefaultApartFromTheSidebarCard() {
        let unset = Self.parseNewTab(nil)
        #expect(!unset.nowPlaying.newTab, "the New Tab player shows by default (u8394)")
        #expect(unset.nowPlaying.enabled == false, "the sidebar card is on by default")
        #expect(unset.diagnostics.isEmpty, "\(unset.diagnostics)")
        let off = Self.parseNewTab(.bool(false), enabled: true)
        #expect(!off.nowPlaying.newTab)
        #expect(off.nowPlaying.enabled, "hiding the New Tab player hid the sidebar card")
        let on = Self.parseNewTab(.bool(true))
        #expect(on.nowPlaying.newTab, "a user who turned the New Tab player on lost it")
    }

    @Test func aBadNewTabValueKeepsThePlayerHiddenAndSaysWhy() {
        let snapshot = Self.parseNewTab(.string("on"))
        #expect(!snapshot.nowPlaying.newTab)
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.newTabNowPlaying" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheNewTabToggleOffByDefaultWithTheOtherNewTabRows() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabNowPlaying"]))
        #expect(descriptor.defaultValue == .bool(false))
        let template = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabTemplate"]))
        #expect(descriptor.section == template.section && descriptor.group == template.group, "not with the New Tab rows")
        #expect(SettingsSchema.agentSettableKeys.contains("tabs.newTabNowPlaying"), "agents cannot set it like tabs.newTabTemplate")
    }

    static func parseOtherApps(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["nowPlaying": .object(["otherApps": $0])])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    /// u8394: the player showed another browser's audio; other apps feed it only when the user says so.
    @Test func otherAppsAreLeftOutUnlessTheUserTurnsThemOn() throws {
        let unset = Self.parseOtherApps(nil)
        #expect(!unset.nowPlaying.otherApps, "other apps feed Now Playing by default")
        #expect(unset.diagnostics.isEmpty, "\(unset.diagnostics)")
        #expect(Self.parseOtherApps(.bool(true)).nowPlaying.otherApps)
        let bad = Self.parseOtherApps(.string("yes"))
        #expect(!bad.nowPlaying.otherApps)
        #expect(bad.diagnostics.contains { $0.path == "sidebar.nowPlaying.otherApps" }, "\(bad.diagnostics)")
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "nowPlaying", "otherApps"]))
        #expect(descriptor.defaultValue == .bool(false))
        let card = try #require(SettingsSchema.descriptor(for: ["sidebar", "nowPlaying", "enabled"]))
        #expect(descriptor.section == card.section && descriptor.group == card.group, "not next to Show Now Playing")
    }
}
