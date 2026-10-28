import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPalette
@testable import CmuxNextSettings
import CmuxNextSettingsWindow
import Foundation
import Testing

/// The palette's Settings page offers what the Settings page offers: Energy Saver's
/// row only while its feature is on, and its "On Battery" only on a Mac with a battery
/// (``SettingsAvailability``).
@MainActor @Suite(.serialized) struct SettingsPaletteAvailabilityTests {
    private static let energySaver = "energy.saver"

    private func rows(_ availability: SettingsAvailability) async throws -> [PaletteSettingRow] {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-palette-availability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return SettingsPaletteSource(settings: settings, availability: { availability }, themeColors: { [] }).rows
    }

    private func optionIDs(_ row: PaletteSettingRow?) -> [String] {
        guard case .options(let options, _)? = row?.kind else { return [] }
        return options.map(\.id)
    }

    private static func id(_ mode: String) -> String { JSONValue.string(mode).compactText }

    @Test func theFeatureOffLeavesTheRowOut() async throws {
        let hidden = EnergySaverSetting().availability(featureEnabled: false, hasBattery: true)
        let rows = try await rows(hidden)
        #expect(!rows.contains { $0.id == Self.energySaver })
        #expect(!rows.isEmpty, "only the hidden row is left out")
    }

    @Test func aMacWithNoBatteryIsNotOfferedOnBattery() async throws {
        let rows = try await rows(EnergySaverSetting().availability(featureEnabled: true, hasBattery: false))
        let row = rows.first { $0.id == Self.energySaver }
        #expect(optionIDs(row) == ["auto", "always", "off"].map(Self.id))
    }

    @Test func aLaptopIsOfferedEveryMode() async throws {
        let rows = try await rows(EnergySaverSetting().availability(featureEnabled: true, hasBattery: true))
        let row = rows.first { $0.id == Self.energySaver }
        #expect(optionIDs(row) == ["auto", "onBattery", "always", "off"].map(Self.id))
    }

    /// The deep link (`openSettings setting:energy.saver` from the CLI, the socket or a link) follows
    /// the same availability: with the feature off it names no row, so `SettingsWindowService.show`
    /// refuses it as it refuses an unknown key.
    @Test func theDeepLinkRefusesAHiddenRow() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == Self.energySaver })
        let hidden = EnergySaverSetting().availability(featureEnabled: false, hasBattery: true)
        #expect(SettingsAnchor(key: Self.energySaver, availability: hidden) == nil)
        #expect(SettingsDeepLink(setting: Self.energySaver).anchor(availability: hidden) == nil)
        let shown = EnergySaverSetting().availability(featureEnabled: true, hasBattery: false)
        #expect(SettingsAnchor(key: Self.energySaver, availability: shown) == .setting(row))
    }
}
