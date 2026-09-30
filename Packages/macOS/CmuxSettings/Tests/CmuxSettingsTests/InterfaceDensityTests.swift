import Foundation
import Testing
@testable import CmuxSettings

struct InterfaceDensityTests {
    @Test func storedReadsCatalogKeyAndFallsBackToStandard() throws {
        let suite = "InterfaceDensityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = AppCatalogSection().interfaceDensity

        #expect(key.id == "app.density")
        #expect(key.userDefaultsKey == InterfaceDensity.userDefaultsKey)
        #expect(key.defaultValue == .standard)
        #expect(InterfaceDensity.stored(in: defaults) == .standard)

        for density in InterfaceDensity.allCases {
            defaults.set(density.rawValue, forKey: InterfaceDensity.userDefaultsKey)
            #expect(InterfaceDensity.stored(in: defaults) == density)
            #expect(key.value(in: defaults) == density)
        }

        defaults.set("cozy", forKey: InterfaceDensity.userDefaultsKey)
        #expect(InterfaceDensity.stored(in: defaults) == .standard)
    }

    @Test func onlyCompactFoldsActionsBehindHover() {
        #expect(InterfaceDensity.allCases.filter(\.foldsActionsBehindHover) == [.compact])
    }
}
