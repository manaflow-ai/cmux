import Foundation
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct MobileDisplaySettingsTests {
    /// Builds a scoped defaults suite so tests never touch `.standard`.
    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let suiteName = "MobileDisplaySettingsTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func previewLineCountDefaultsToTwoWithoutAWrite() throws {
        let defaults = try makeDefaults("defaults")
        let settings = MobileDisplaySettings(defaults: defaults)
        #expect(settings.workspacePreviewLineCount == 2)
        // The default must not be persisted just by reading it.
        #expect(defaults.object(forKey: "cmux.mobile.workspacePreviewLineCount") == nil)
    }

    @Test func previewLineCountPersistsAcrossInstances() throws {
        let defaults = try makeDefaults("persists")
        let settings = MobileDisplaySettings(defaults: defaults)
        settings.workspacePreviewLineCount = 1
        #expect(MobileDisplaySettings(defaults: defaults).workspacePreviewLineCount == 1)
    }

    @Test func previewLineCountClampsToSupportedRange() throws {
        let defaults = try makeDefaults("clamps")
        let settings = MobileDisplaySettings(defaults: defaults)
        settings.workspacePreviewLineCount = 99
        #expect(settings.workspacePreviewLineCount == 2)
        settings.workspacePreviewLineCount = 0
        #expect(settings.workspacePreviewLineCount == 1)

        // A corrupted stored value reads back clamped, not raw.
        defaults.set(-5, forKey: "cmux.mobile.workspacePreviewLineCount")
        #expect(MobileDisplaySettings(defaults: defaults).workspacePreviewLineCount == 1)
    }

    @Test func debugLayoutSettingsDefaultWithoutAWrite() throws {
        let defaults = try makeDefaults("debugLayoutDefaults")
        let settings = MobileDisplaySettings(defaults: defaults)
        #expect(settings.unreadIndicatorLeftShift == 1.5)
        #expect(settings.profilePictureLeftShift == 4)
        #expect(settings.profilePictureSize == 45)
        #expect(defaults.object(forKey: "cmux.mobile.debug.unreadIndicatorLeftShift.v2") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.debug.profilePictureLeftShift") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.debug.profilePictureSize") == nil)
    }

    @Test func debugLayoutSettingsPersistAcrossInstances() throws {
        let defaults = try makeDefaults("debugLayoutPersists")
        let settings = MobileDisplaySettings(defaults: defaults)
        settings.unreadIndicatorLeftShift = 7
        settings.profilePictureLeftShift = 11
        settings.profilePictureSize = 55

        let reloaded = MobileDisplaySettings(defaults: defaults)
        #expect(reloaded.unreadIndicatorLeftShift == 7)
        #expect(reloaded.profilePictureLeftShift == 11)
        #expect(reloaded.profilePictureSize == 55)
    }

    @Test func debugLayoutSettingsClampToSupportedRanges() throws {
        let defaults = try makeDefaults("debugLayoutClamps")
        let settings = MobileDisplaySettings(defaults: defaults)
        settings.unreadIndicatorLeftShift = 99
        settings.profilePictureLeftShift = -1
        settings.profilePictureSize = 100
        #expect(settings.unreadIndicatorLeftShift == 24)
        #expect(settings.profilePictureLeftShift == 0)
        #expect(settings.profilePictureSize == 64)

        defaults.set(-5.0, forKey: "cmux.mobile.debug.unreadIndicatorLeftShift.v2")
        defaults.set(99.0, forKey: "cmux.mobile.debug.profilePictureLeftShift")
        defaults.set(1.0, forKey: "cmux.mobile.debug.profilePictureSize")
        let reloaded = MobileDisplaySettings(defaults: defaults)
        #expect(reloaded.unreadIndicatorLeftShift == 0)
        #expect(reloaded.profilePictureLeftShift == 24)
        #expect(reloaded.profilePictureSize == 36)
    }
}
