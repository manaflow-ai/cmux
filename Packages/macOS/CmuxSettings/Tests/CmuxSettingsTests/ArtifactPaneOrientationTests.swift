import Foundation
import Testing
@testable import CmuxSettings

@Suite("Artifact pane orientation settings")
struct ArtifactPaneOrientationTests {
    private static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "cmux.tests.artifact-pane-orientation.\(UUID().uuidString)")!
    }

    @Test
    func defaultsToHistoricalRightSideAndPersistsVerticalChoice() {
        let defaults = Self.scratchDefaults()
        let key = AppCatalogSection().artifactPaneOrientation

        #expect(key.value(in: defaults) == .horizontal)
        #expect(key.defaultValue.defaultDirectionRawValue == "right")

        key.set(.vertical, in: defaults)

        #expect(key.value(in: defaults) == .vertical)
        #expect(key.value(in: defaults).defaultDirectionRawValue == "down")
    }

    @Test
    func undecodableStoredValueFallsBackToHorizontal() {
        let defaults = Self.scratchDefaults()
        let key = AppCatalogSection().artifactPaneOrientation
        defaults.set("diagonal", forKey: key.userDefaultsKey)

        #expect(key.value(in: defaults) == .horizontal)
    }
}
