import CmuxNextActions
import CmuxNextAppearance
@testable import CmuxNextSettings
import Foundation
import Testing

/// `appearance.background` replaced `appearance.backdropArt`, and the app still paints a painting
/// the old key names while the new key is absent. Settings and the palette read the same value
/// the app applies, so they show that painting instead of None, and a pick or a reset of the
/// background removes the old key, so it can never apply again behind the new value.
@MainActor @Suite(.serialized) struct BackdropLegacyKeySettingsTests {
    static let art = BackdropArt.allCases[0].rawValue
    static let background = ["appearance", "background"]
    static let backdropArt = ["appearance", "backdropArt"]

    static var descriptor: SettingDescriptor {
        get throws { try #require(SettingsSchema.descriptor(for: background)) }
    }

    @Test func settingsShowThePaintingTheOldKeyNames() throws {
        let root = JSONValue.object(["appearance": .object(["backdropArt": .string(Self.art)])])
        #expect(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).backdropArt?.rawValue == Self.art)
        #expect(try Self.descriptor.effectiveValue(in: root) == .string(Self.art))
        #expect(try Self.descriptor.isCustomized(in: root))
    }

    /// The old key took bundled art only: a retired id shows the work that stands in for it, and
    /// a value it never took (the desktop) shows None, which is what the app paints.
    @Test func theOldKeyShowsWhatItPaints() throws {
        let retired = JSONValue.object(["appearance": .object(["backdropArt": .string("wheat-field-with-cypresses")])])
        let painted = try #require(CmuxConfigSnapshot.parse(retired, validDensities: [], validMetrics: []).backdropArt)
        #expect(try Self.descriptor.effectiveValue(in: retired) == .string(painted.rawValue))
        let desktop = JSONValue.object(["appearance": .object(["backdropArt": .string(BackdropSelection.desktopID)])])
        #expect(CmuxConfigSnapshot.parse(desktop, validDensities: [], validMetrics: []).backdropArt == nil)
        #expect(try Self.descriptor.effectiveValue(in: desktop) == .string("none"))
    }

    @Test func theNewKeyWinsOverTheOldOne() throws {
        let root = JSONValue.object(["appearance": .object(["backdropArt": .string(Self.art), "background": .string("none")])])
        #expect(try Self.descriptor.effectiveValue(in: root) == .string("none"))
    }

    @Test func choosingOrResettingTheBackgroundRemovesTheOldKey() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-backdrop-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: "cmux-next.json")
        let legacy = #"{ "appearance": { "backdropArt": "\#(Self.art)" } }"#
        try Data(legacy.utf8).write(to: url)
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()

        try await settings.setSetting(at: Self.background, to: .string("none"), by: .user)
        #expect(settings.snapshot.root.value(at: Self.backdropArt) == nil)
        #expect(settings.snapshot.backdropArt == nil)

        try Data(legacy.utf8).write(to: url)
        await settings.reload()
        try await settings.setSetting(at: Self.background, to: nil, by: .user)
        #expect(settings.snapshot.root.value(at: Self.backdropArt) == nil)
        #expect(settings.snapshot.backdropArt == nil)
    }
}
