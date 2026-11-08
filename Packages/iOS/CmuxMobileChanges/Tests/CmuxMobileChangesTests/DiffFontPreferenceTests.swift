import Foundation
import Testing

@testable import CmuxMobileChanges

@MainActor
@Suite struct DiffFontPreferenceTests {
    @Test func defaultsToTwelvePointsAndPersists() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let preference = DiffFontPreference(defaults: context.defaults)

        #expect(preference.pointSize == 12)
        preference.pointSize = 15.5
        #expect(preference.pointSize == 15.5)
        #expect(DiffFontPreference(defaults: context.defaults).pointSize == 15.5)
    }

    @Test func clampsPointSizeAndRepairsNonFiniteStorage() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let key = "test.diff.font"
        let preference = DiffFontPreference(defaults: context.defaults, key: key)

        preference.pointSize = 2
        #expect(preference.pointSize == 9)
        preference.pointSize = 100
        #expect(preference.pointSize == 22)
        preference.pointSize = .infinity
        #expect(preference.pointSize == 12)
        context.defaults.set(Double.nan, forKey: key)
        #expect(preference.pointSize == 12)
    }

    private func makeContext() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "CmuxMobileChangesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
