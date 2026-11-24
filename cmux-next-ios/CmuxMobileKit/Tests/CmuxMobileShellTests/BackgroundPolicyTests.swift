import Foundation
import Testing
@testable import CmuxMobileDesign

#if os(iOS)
/// The background policy prototype: one rule for every screen's ground (Settings > Appearance > Backgrounds).
@Suite struct BackgroundPolicyTests {
    static func defaults() -> UserDefaults {
        let name = "BackgroundPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func currentKeepsEveryScreensOwnGround() {
        for level in [CmuxMobileGroundLevel.root, .page, .sheet, .chat] {
            #expect(CmuxMobileBackgroundPolicy.current.ground(level) == .legacy)
        }
    }

    @Test func wallpaperEverywhereTintsReadingSurfacesHarder() {
        #expect(CmuxMobileBackgroundPolicy.canvas.ground(.root) == .wallpaper(minTint: 0))
        for level in [CmuxMobileGroundLevel.page, .sheet, .chat] {
            #expect(CmuxMobileBackgroundPolicy.canvas.ground(level) == .wallpaper(minTint: 0.78))
        }
    }

    @Test func wallpaperOnTabsOnlyAtTheRoots() {
        #expect(CmuxMobileBackgroundPolicy.layered.ground(.root) == .wallpaper(minTint: 0))
        for level in [CmuxMobileGroundLevel.page, .sheet, .chat] {
            #expect(CmuxMobileBackgroundPolicy.layered.ground(level) == .solid)
        }
    }

    @Test func solidEverywhereNeverShowsTheWallpaper() {
        for level in [CmuxMobileGroundLevel.root, .page, .sheet, .chat] {
            #expect(CmuxMobileBackgroundPolicy.flat.ground(level) == .solid)
        }
    }

    @Test func theChoiceIsKeptAndDefaultsToCurrent() {
        let defaults = Self.defaults()
        let setting = CmuxMobileBackgroundSetting(defaults: defaults, arguments: [])
        #expect(setting.policy == .current)
        setting.policy = .layered
        #expect(CmuxMobileBackgroundSetting(defaults: defaults, arguments: []).policy == .layered)
    }

    @Test func aLaunchArgumentPicksThePolicyForScreenshots() {
        let setting = CmuxMobileBackgroundSetting(defaults: Self.defaults(), arguments: ["app", "-cmux-mobile-bg-policy", "flat"])
        #expect(setting.policy == .flat)
    }
}
#endif
