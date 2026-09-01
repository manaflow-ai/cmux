import Foundation
import Testing
@testable import CmuxSettings

@Suite("Video background settings")
struct VideoBackgroundSettingsTests {
    @Test func dimOpacityNormalizationClampsAndRejectsNonFiniteValues() {
        let policy = VideoBackgroundSettings()
        #expect(policy.normalizedDimOpacity(nil) == VideoBackgroundSettings.defaultDimOpacity)
        #expect(policy.normalizedDimOpacity(.nan) == VideoBackgroundSettings.defaultDimOpacity)
        #expect(policy.normalizedDimOpacity(.infinity) == VideoBackgroundSettings.defaultDimOpacity)
        #expect(policy.normalizedDimOpacity(-0.5) == 0.0)
        #expect(policy.normalizedDimOpacity(1.5) == 1.0)
        #expect(policy.normalizedDimOpacity(0.65) == 0.65)
    }

    @Test func defaultsAreOffWithNoSource() {
        let suiteName = "VideoBackgroundSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let policy = VideoBackgroundSettings()
        #expect(policy.isEnabled(defaults: defaults) == false)
        #expect(policy.sourceText(defaults: defaults).isEmpty)
        #expect(policy.dimOpacity(defaults: defaults) == VideoBackgroundSettings.defaultDimOpacity)
        #expect(policy.isMuted(defaults: defaults) == true)
    }

    @Test func readsConfiguredValuesAndClampsStoredDimOpacity() {
        let suiteName = "VideoBackgroundSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: VideoBackgroundSettings.enabledKey)
        defaults.set("https://www.youtube.com/watch?v=dQw4w9WgXcQ", forKey: VideoBackgroundSettings.sourceKey)
        defaults.set(4.2, forKey: VideoBackgroundSettings.dimOpacityKey)
        defaults.set(false, forKey: VideoBackgroundSettings.mutedKey)

        let policy = VideoBackgroundSettings()
        #expect(policy.isEnabled(defaults: defaults) == true)
        #expect(policy.isMuted(defaults: defaults) == false)
        #expect(policy.sourceText(defaults: defaults) == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(policy.dimOpacity(defaults: defaults) == 1.0)
    }
}
