import Foundation
import Testing

@Suite("Simulator localization catalog")
struct SimulatorLocalizationCatalogTests {
    @Test("Worker request routing failures have English and Japanese copy")
    func workerRequestRoutingFailuresAreLocalized() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            repositoryRoot.deleteLastPathComponent()
        }
        let catalogURL = repositoryRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try #require(catalog["strings"] as? [String: Any])

        for key in [
            "simulator.failure.workerRequestCapacityExceeded",
            "simulator.failure.workerRequestIdentifierDuplicate",
        ] {
            let entry = strings[key] as? [String: Any]
            #expect(entry != nil)
            let localizations = entry?["localizations"] as? [String: Any]
            for language in ["en", "ja"] {
                let localization = localizations?[language] as? [String: Any]
                let stringUnit = localization?["stringUnit"] as? [String: Any]
                let value = stringUnit?["value"] as? String
                #expect(value?.isEmpty == false)
            }
        }
    }
}
