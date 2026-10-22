@testable import CmuxNextApp
@testable import CmuxNextSettings
import Foundation
import Testing

/// Leo (2026-10-21, "why do we not have more aggressive hibernation"): a hidden browser page
/// hibernates after 10 minutes by default, not 30. PR 23083 measured what that frees: a
/// Chromium tab's renderer (79 MB) or a WebKit page's (61 MB), back in about 160 ms with its
/// picture shown meanwhile. "moderate" (30 minutes) stays a choice.
@Suite struct HibernationDefaultTests {
    @Test func aHiddenPageHibernatesAfterTenMinutesByDefault() {
        #expect(BrowserHibernationSetting.fallback.mode == .aggressive)
        #expect(BrowserHibernationSetting.fallback.hiddenMinutes == 10)
    }

    @Test func aConfigWithoutTheSettingHibernatesAfterTenMinutes() {
        let (setting, diagnostics) = BrowserHibernationSetting.parse(.object([:]))
        #expect(setting.hiddenMinutes == 10)
        #expect(diagnostics.isEmpty)
    }

    /// The Settings window, cmux.json's schema and the managed-preferences exports show the
    /// default the app applies.
    @Test func theSchemaDefaultIsTheDefaultTheAppApplies() {
        let descriptor = SettingsSchema.descriptor(for: BrowserHibernationSetting.configPath)
        #expect(descriptor?.defaultValue == BrowserHibernationSetting.fallback.configValue)
    }

    /// 30 minutes is still a choice.
    @Test func moderateStillHibernatesAfterThirtyMinutes() {
        let (setting, _) = BrowserHibernationSetting.parse(.object(["browser": .object(["hibernation": .string("moderate")])]))
        #expect(setting.hiddenMinutes == 30)
    }
}
