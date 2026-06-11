import CoreGraphics
import Testing
@testable import CmuxSettingsUI

@Suite("SettingsVisibleSectionResolver")
struct SettingsVisibleSectionResolverTests {
    @Test func returnsNilWhenNoSectionFramesExist() {
        let section = SettingsVisibleSectionResolver.visibleSection(in: [:])
        #expect(section == nil)
    }

    @Test func selectsFirstUpcomingSectionBeforeAnySectionCrossesActivationLine() {
        let frames: [SettingsSectionID: CGRect] = [
            .account: frame(y: 20),
            .app: frame(y: 260),
        ]

        let section = SettingsVisibleSectionResolver.visibleSection(in: frames)

        #expect(section == .account)
    }

    @Test func selectsNearestSectionWhoseTopCrossedActivationLine() {
        let frames: [SettingsSectionID: CGRect] = [
            .account: frame(y: -520),
            .app: frame(y: -12),
            .terminal: frame(y: 340),
        ]

        let section = SettingsVisibleSectionResolver.visibleSection(in: frames)

        #expect(section == .app)
    }

    @Test func supportsInlineBrowserImportSectionWhenItsMarkerCrossesTop() {
        let frames: [SettingsSectionID: CGRect] = [
            .browser: frame(y: -420, height: 1_000),
            .browserImport: frame(y: -8),
            .globalHotkey: frame(y: 180),
        ]

        let section = SettingsVisibleSectionResolver.visibleSection(in: frames)

        #expect(section == .browserImport)
    }

    @Test func fallsBackToParentBrowserSectionAfterInlineImportScrollsPastTop() {
        let frames: [SettingsSectionID: CGRect] = [
            .browser: frame(y: -520, height: 1_000),
            .browserImport: frame(y: -180),
            .globalHotkey: frame(y: 240),
        ]

        let section = SettingsVisibleSectionResolver.visibleSection(in: frames)

        #expect(section == .browser)
    }

    @Test func customActivationLineSelectsSectionBeforeItReachesViewportTop() {
        let configuration = SettingsVisibleSectionResolver.Configuration(activationY: 40)
        let frames: [SettingsSectionID: CGRect] = [
            .account: frame(y: -220),
            .app: frame(y: 24),
            .terminal: frame(y: 280),
        ]

        let section = SettingsVisibleSectionResolver.visibleSection(
            in: frames,
            configuration: configuration
        )

        #expect(section == .app)
    }

    /// Builds a fixed-size section frame for resolver tests.
    ///
    /// - Parameter y: Top-edge y coordinate in the scroll coordinate space.
    /// - Returns: A rectangle with stable dimensions and the supplied top edge.
    private func frame(y: CGFloat, height: CGFloat = 100) -> CGRect {
        CGRect(x: 0, y: y, width: 100, height: height)
    }
}
