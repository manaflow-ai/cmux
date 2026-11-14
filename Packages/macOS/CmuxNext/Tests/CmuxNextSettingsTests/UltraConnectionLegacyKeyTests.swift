import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// `remote.ultra` (Off, Auto or Always) replaced the toggle `remote.ultraMode`, and the tunnels
/// still read the toggle's `true` as Always while `remote.ultra` is absent (cmux-tui-util
/// `user_settings::ultra`). The retired-keys table says so (`replaced_by`), so the Settings row
/// shows Always for it, and a pick or a reset of the row removes the old key, so Always never
/// applies behind the new value.
@MainActor @Suite(.serialized) struct UltraConnectionLegacyKeyTests {
    static let ultra = ["remote", "ultra"]
    static let ultraMode = ["remote", "ultraMode"]

    static var descriptor: SettingDescriptor {
        get throws { try #require(SettingsSchema.descriptor(for: ultra)) }
    }

    @Test func theRowShowsWhatTheTunnelsApply() throws {
        let on = JSONValue.object(["remote": .object(["ultraMode": .bool(true)])])
        #expect(CmuxConfigSnapshot.parse(on, validDensities: [], validMetrics: []).remote.ultra == .always)
        #expect(try Self.descriptor.effectiveValue(in: on) == .string("always"))
        #expect(try Self.descriptor.isCustomized(in: on))
        let off = JSONValue.object(["remote": .object(["ultraMode": .bool(false)])])
        #expect(CmuxConfigSnapshot.parse(off, validDensities: [], validMetrics: []).remote.ultra == .auto)
        #expect(try Self.descriptor.effectiveValue(in: off) == .string("auto"))
        let both = JSONValue.object(["remote": .object(["ultraMode": .bool(true), "ultra": .string("off")])])
        #expect(try Self.descriptor.effectiveValue(in: both) == .string("off"), "the new key wins")
    }

    @Test func pickingOrResettingTheRowRemovesTheOldKey() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-ultra-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: "cmux-next.json")
        let legacy = #"{ "remote": { "ultraMode": true } }"#
        try Data(legacy.utf8).write(to: url)
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        #expect(settings.snapshot.remote.ultra == .always)

        // Auto is the default: the write removes `remote.ultra`, and the old key with it.
        try await settings.setSetting(at: Self.ultra, to: .string("auto"), by: .user)
        #expect(settings.snapshot.root.value(at: Self.ultraMode) == nil)
        #expect(settings.snapshot.remote.ultra == .auto)

        try Data(legacy.utf8).write(to: url)
        await settings.reload()
        try await settings.setSetting(at: Self.ultra, to: .string("off"), by: .user)
        #expect(settings.snapshot.root.value(at: Self.ultraMode) == nil)
        #expect(settings.snapshot.remote.ultra == .off)

        try Data(legacy.utf8).write(to: url)
        await settings.reload()
        try await settings.setSetting(at: Self.ultra, to: nil, by: .user)
        #expect(settings.snapshot.root.value(at: Self.ultraMode) == nil)
        #expect(settings.snapshot.remote.ultra == .auto)
    }
}
