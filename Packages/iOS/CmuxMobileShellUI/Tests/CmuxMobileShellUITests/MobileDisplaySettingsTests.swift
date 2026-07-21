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

    @Test func showAltScreenNoticeDefaultsToTrueWithoutAWrite() throws {
        let defaults = try makeDefaults("altScreenNoticeDefaults")
        let settings = MobileDisplaySettings(defaults: defaults)
        #expect(settings.showAltScreenNotice)
        #expect(defaults.object(forKey: "cmux.mobile.showAltScreenNotice") == nil)
    }

    @Test func showAltScreenNoticePersistsFalseAcrossInstances() throws {
        let defaults = try makeDefaults("altScreenNoticePersistsFalse")
        let settings = MobileDisplaySettings(defaults: defaults)
        settings.showAltScreenNotice = false
        #expect(MobileDisplaySettings(defaults: defaults).showAltScreenNotice == false)
    }

    @Test func showAltScreenNoticePersistsTrueAcrossInstances() throws {
        let defaults = try makeDefaults("altScreenNoticePersistsTrue")
        let settings = MobileDisplaySettings(defaults: defaults)
        settings.showAltScreenNotice = false
        settings.showAltScreenNotice = true
        #expect(MobileDisplaySettings(defaults: defaults).showAltScreenNotice)
    }

    @Test func showMissingFilesDefaultsToFalseWithoutAWrite() throws {
        let defaults = try makeDefaults("showMissingFilesDefaults")
        let settings = MobileDisplaySettings(defaults: defaults)
        #expect(!settings.showMissingFiles)
        #expect(defaults.object(forKey: "cmux.mobile.showMissingFiles") == nil)
    }

    @Test func showMissingFilesPersistsAcrossInstances() throws {
        let defaults = try makeDefaults("showMissingFilesPersists")
        let settings = MobileDisplaySettings(defaults: defaults)
        settings.showMissingFiles = true
        #expect(MobileDisplaySettings(defaults: defaults).showMissingFiles)
        settings.showMissingFiles = false
        #expect(!MobileDisplaySettings(defaults: defaults).showMissingFiles)
    }

    @Test func terminalFilesChipDefaultsToFalseWithoutAWrite() throws {
        let defaults = try makeDefaults("terminalFilesChipDefaults")
        let settings = MobileDisplaySettings(defaults: defaults)
        #expect(!settings.terminalFilesChipEnabled)
        #expect(defaults.object(forKey: "cmux.mobile.terminalFilesChipEnabled") == nil)
    }

    @Test func terminalFilesChipPersistsAcrossInstances() throws {
        let defaults = try makeDefaults("terminalFilesChipPersists")
        let settings = MobileDisplaySettings(defaults: defaults)
        settings.terminalFilesChipEnabled = true
        #expect(MobileDisplaySettings(defaults: defaults).terminalFilesChipEnabled)
        settings.terminalFilesChipEnabled = false
        #expect(!MobileDisplaySettings(defaults: defaults).terminalFilesChipEnabled)
    }

    @Test func taskComposerDefaultsToFalseWithoutAWrite() throws {
        let defaults = try makeDefaults("taskComposerDefaults")
        let settings = MobileDisplaySettings(defaults: defaults)
        #expect(!settings.taskComposerEnabled)
        #expect(defaults.object(forKey: "cmux.mobile.taskComposerEnabled") == nil)
    }

    @Test func taskComposerPersistsAcrossInstances() throws {
        let defaults = try makeDefaults("taskComposerPersists")
        let settings = MobileDisplaySettings(defaults: defaults)
        settings.taskComposerEnabled = true
        #expect(MobileDisplaySettings(defaults: defaults).taskComposerEnabled)
        settings.taskComposerEnabled = false
        #expect(!MobileDisplaySettings(defaults: defaults).taskComposerEnabled)
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
        #expect(settings.taskComposerShellIconVariant == .current)
        #expect(defaults.object(forKey: "cmux.mobile.debug.taskComposerShellIconVariant.v1") == nil)
    }

    @Test func shellIconExperimentsAreScopedToDebugBuilds() throws {
        let defaults = try makeDefaults("shellIconBuildScope")
        defaults.set(
            TaskComposerShellIconVariant.medium86.rawValue,
            forKey: "cmux.mobile.debug.taskComposerShellIconVariant.v1"
        )

        let settings = MobileDisplaySettings(defaults: defaults)
        #if DEBUG
        #expect(settings.taskComposerShellIconVariant == .medium86)
        #expect(TaskComposerShellIconVariant.medium86.glyphScale == 0.86)
        #else
        #expect(settings.taskComposerShellIconVariant == .current)
        let current = TaskComposerShellIconVariant.current
        for variant in TaskComposerShellIconVariant.allCases {
            #expect(variant.glyphScale == current.glyphScale)
            #expect(variant.glyphWeight == current.glyphWeight)
            #expect(variant.glyphOpacity == current.glyphOpacity)
            #expect(variant.circleScale == current.circleScale)
            #expect(variant.circleOpacityScale == current.circleOpacityScale)
        }
        #endif
    }

    #if DEBUG
    @Test func shellIconVariantPersistsAndRejectsUnknownValues() throws {
        let defaults = try makeDefaults("shellIconVariant")
        let settings = MobileDisplaySettings(defaults: defaults)
        settings.taskComposerShellIconVariant = .medium86
        #expect(MobileDisplaySettings(defaults: defaults).taskComposerShellIconVariant == .medium86)

        defaults.set("removed-variant", forKey: "cmux.mobile.debug.taskComposerShellIconVariant.v1")
        #expect(MobileDisplaySettings(defaults: defaults).taskComposerShellIconVariant == .current)
    }
    #endif

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
