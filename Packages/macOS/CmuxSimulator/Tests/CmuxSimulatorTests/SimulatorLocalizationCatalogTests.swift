import Foundation
import Testing

@Suite("Simulator localization catalog")
struct SimulatorLocalizationCatalogTests {
    @Test("Worker request routing failures have English and Japanese copy")
    func workerRequestRoutingFailuresAreLocalized() throws {
        try expectLocalized([
            "simulator.failure.workerRequestCapacityExceeded",
            "simulator.failure.workerRequestIdentifierDuplicate",
        ])
    }

    @Test("UI automation messages have English and Japanese copy")
    func uiAutomationMessagesAreLocalized() throws {
        try expectLocalized([
            "cli.simulator.error.uiDirectionInvalid",
            "cli.simulator.error.uiElementRefInvalid",
            "cli.simulator.error.uiElementRefNotFound",
            "cli.simulator.error.uiFocusUnavailable",
            "cli.simulator.error.uiGesturePresetInvalid",
            "cli.simulator.error.uiOperationInvalid",
            "cli.simulator.error.uiRoleInvalid",
            "cli.simulator.error.uiSnapshotDidNotSettle",
            "cli.simulator.error.uiSnapshotExpired",
            "cli.simulator.error.uiSnapshotMissing",
            "cli.simulator.error.uiSnapshotViewportMissing",
            "cli.simulator.error.uiStableSelectorUnavailable",
            "cli.simulator.error.uiStateChanged",
            "cli.simulator.error.uiTargetNotActionable",
            "cli.simulator.error.uiTextUnsupported",
            "cli.simulator.error.uiWaitPredicateInvalid",
            "cli.simulator.error.uiWaitTargetAmbiguous",
            "cli.simulator.error.uiWaitTimeout",
            "cli.simulator.output.uiSnapshotTruncated",
            "cli.simulator.output.uiSnapshotUnchanged",
            "cli.simulator.output.uiWaitMatched",
            "cli.simulator.recovery.captureSnapshot",
            "cli.simulator.recovery.chooseAdvertisedAction",
            "cli.simulator.recovery.refineWait",
            "cli.simulator.warning.uiSnapshotRefreshFailed",
        ])
    }

    private func expectLocalized(_ keys: [String]) throws {
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

        for key in keys {
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
