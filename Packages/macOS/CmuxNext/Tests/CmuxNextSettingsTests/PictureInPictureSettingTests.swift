import CmuxNextSettings
import Testing

/// `media.pictureInPicture.enabled`: on by default, so cmux keeps offering Picture in Picture for a
/// page's video; Settings lists the toggle in Browser > Media, an agent may change it, and a bad
/// value keeps the default with a diagnostic.
struct PictureInPictureSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["media": .object(["pictureInPicture": .object(["enabled": $0])])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func onByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.nowPlaying.pictureInPicture)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOff() {
        #expect(Self.parse(.bool(false)).nowPlaying.pictureInPicture == false)
        #expect(Self.parse(.bool(true)).nowPlaying.pictureInPicture)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("no"))
        #expect(snapshot.nowPlaying.pictureInPicture)
        #expect(snapshot.diagnostics.contains { $0.path == "media.pictureInPicture.enabled" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOnInBrowserMedia() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["media", "pictureInPicture", "enabled"]))
        #expect(descriptor.defaultValue == .bool(true))
        #expect(descriptor.section == .browser)
        #expect(descriptor.textKeys.group == "settings.group.media")
        #expect(SettingsSchema.agentSettableKeys.contains("media.pictureInPicture.enabled"))
    }
}
