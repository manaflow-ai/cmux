import CmuxNextSettings
import Testing

/// `appearance.backdropArt` is the legacy key `appearance.background` replaced; the app still
/// paints it when `appearance.background` is absent (BackdropSelectionSetting). Settings showed the
/// row's default instead, so the wallpaper card highlighted Daily over the person's own painting
/// (#22379 review). The row now reads the legacy key the way the parser does.
struct LegacyBackdropArtValueTests {
    private static let path = ["appearance", "background"]

    private func root(_ appearance: [String: JSONValue]) -> JSONValue {
        .object(["appearance": .object(appearance)])
    }

    @Test func onlyTheLegacyKeyShowsItsPainting() throws {
        let row = try #require(SettingsSchema.descriptor(for: Self.path))
        let legacy = root(["backdropArt": .string("van-gogh-starry-night")])
        #expect(row.storedValue(in: legacy) == .string("van-gogh-starry-night"))
        #expect(row.effectiveValue(in: legacy) == .string("van-gogh-starry-night"))
    }

    @Test func aLegacyNoneShowsNoWallpaper() throws {
        let row = try #require(SettingsSchema.descriptor(for: Self.path))
        #expect(row.effectiveValue(in: root(["backdropArt": .string("none")])) == .string("none"))
    }

    @Test func theCurrentKeyWinsOverTheLegacyOne() throws {
        let row = try #require(SettingsSchema.descriptor(for: Self.path))
        let both = root(["background": .string("daily"), "backdropArt": .string("van-gogh-starry-night")])
        #expect(row.effectiveValue(in: both) == .string("daily"))
    }
}
