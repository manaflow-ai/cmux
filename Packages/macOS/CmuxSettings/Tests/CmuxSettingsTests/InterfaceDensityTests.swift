import Foundation
import Testing
@testable import CmuxSettings

struct InterfaceDensityTests {
    @Test func storedReadsEachDensityAndFallsBackToStandard() throws {
        let suite = "InterfaceDensityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(InterfaceDensity.defaultValue == .standard)
        #expect(InterfaceDensity.stored(in: defaults) == .standard)

        for density in InterfaceDensity.allCases {
            defaults.set(density.rawValue, forKey: InterfaceDensity.userDefaultsKey)
            #expect(InterfaceDensity.stored(in: defaults) == density)
        }

        defaults.set("cozy", forKey: InterfaceDensity.userDefaultsKey)
        #expect(InterfaceDensity.stored(in: defaults) == .standard)
    }

    @Test func settingCodableRoundTripsRawValues() {
        for density in InterfaceDensity.allCases {
            #expect(InterfaceDensity.decodeFromUserDefaults(density.encodeForUserDefaults()) == density)
            #expect(InterfaceDensity.decodeFromJSON(density.encodeForJSON()) == density)
            #expect(density.encodeForJSON() as? String == density.rawValue)
        }
        #expect(InterfaceDensity.decodeFromJSON("cozy") == nil)
    }

    @Test func onlyCompactFoldsActionsBehindHover() {
        #expect(InterfaceDensity.allCases.filter(\.foldsActionsBehindHover) == [.compact])
    }
}
