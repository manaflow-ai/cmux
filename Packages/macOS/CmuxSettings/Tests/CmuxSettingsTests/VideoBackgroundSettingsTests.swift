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
        #expect(policy.volume(defaults: defaults) == VideoBackgroundSettings.defaultVolume)
        #expect(policy.quality(defaults: defaults) == VideoBackgroundSettings.defaultQuality)
        #expect(policy.effectiveSourceTexts(defaults: defaults).isEmpty)
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
        defaults.set([" first ", "", "second"], forKey: VideoBackgroundSettings.queueKey)
        defaults.set("4k", forKey: VideoBackgroundSettings.qualityKey)
        defaults.set(-1, forKey: VideoBackgroundSettings.volumeKey)

        let policy = VideoBackgroundSettings()
        #expect(policy.isEnabled(defaults: defaults) == true)
        #expect(policy.isMuted(defaults: defaults) == false)
        #expect(policy.sourceText(defaults: defaults) == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(policy.dimOpacity(defaults: defaults) == 1.0)
        #expect(policy.queue(defaults: defaults) == ["first", "second"])
        #expect(policy.effectiveSourceTexts(defaults: defaults) == ["first", "second"])
        #expect(policy.quality(defaults: defaults) == "2160p")
        #expect(policy.volume(defaults: defaults) == 0.0)
    }

    @Test func normalizedQualityAndQueueStayBounded() {
        let policy = VideoBackgroundSettings()
        #expect(policy.normalizedQuality("4k") == "2160p")
        #expect(policy.normalizedQuality("unknown") == VideoBackgroundSettings.defaultQuality)
        #expect(policy.normalizedVolume(nil) == 1.0)
        #expect(policy.normalizedVolume(.infinity) == 1.0)
        #expect(policy.normalizedVolume(1.5) == 1.0)
        #expect(policy.normalizedVolume(-0.5) == 0.0)
        #expect(policy.normalizedQueue([" a ", "", "b"]) == ["a", "b"])
    }
}
