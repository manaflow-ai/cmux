import Foundation
import Testing
@testable import CmuxSettings

struct PaneResizeStepSettingsTests {
    @Test(arguments: [Int.min, 0, 1, 20, 200, 201, Int.max])
    func readsCurrentClampedValueWithoutMutatingPreferences(value: Int) throws {
        let suite = "PaneResizeStepSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PaneResizeStepSettings(defaults: defaults)
        #expect(settings.currentPixels() == 20)
        defaults.set(value, forKey: PaneResizeStepSettings.key)
        #expect(settings.currentPixels() == UInt16(min(max(value, 1), 200)))
        #expect(defaults.integer(forKey: PaneResizeStepSettings.key) == value)
        defaults.removeObject(forKey: PaneResizeStepSettings.key)
        #expect(settings.currentPixels() == 20)
    }
}
