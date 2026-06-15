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

    @Test func primaryScreenScrollDecouplingDefaultsOnWithoutAWrite() throws {
        let defaults = try makeDefaults("scrollDefault")
        let settings = MobileDisplaySettings(defaults: defaults)
        #expect(settings.decouplePrimaryScreenScroll)
        #expect(defaults.object(forKey: "cmux.mobile.decouplePrimaryScreenScroll") == nil)
    }

    @Test func primaryScreenScrollDecouplingPersistsAcrossInstances() throws {
        let defaults = try makeDefaults("scrollPersists")
        let settings = MobileDisplaySettings(defaults: defaults)
        settings.decouplePrimaryScreenScroll = false
        #expect(MobileDisplaySettings(defaults: defaults).decouplePrimaryScreenScroll == false)
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
}
