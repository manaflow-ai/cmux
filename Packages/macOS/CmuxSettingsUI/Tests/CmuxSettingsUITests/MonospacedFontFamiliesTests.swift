import Foundation
import Testing
@testable import CmuxSettingsUI

/// The terminal font picker offers only fixed-pitch families.
@Suite("Monospaced font families")
struct MonospacedFontFamiliesTests {
    @Test func listsSystemMonospacedFamiliesOnly() {
        let families = MonospacedFontFamilies().load()
        // Menlo and Courier ship with every macOS release; Helvetica is proportional.
        #expect(families.contains("Menlo"))
        #expect(families.contains("Courier"))
        #expect(!families.contains("Helvetica"))
        #expect(!families.contains { $0.hasPrefix(".") })
        #expect(families == families.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}
