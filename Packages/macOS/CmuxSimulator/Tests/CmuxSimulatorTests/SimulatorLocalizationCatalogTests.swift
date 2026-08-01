import Foundation
import Testing

@Suite("Simulator localization catalog")
struct SimulatorLocalizationCatalogTests {
    @Test("Worker request routing failures have English and Japanese copy")
    func workerRequestRoutingFailuresAreLocalized() throws {
        try expectLocalized([
            "simulator.failure.workerRequestCapacityExceeded",
            "simulator.failure.workerRequestIdentifierDuplicate",
        ], languages: ["en", "ja"])
    }

    @Test("UI automation messages cover every app locale")
    func uiAutomationMessagesAreLocalized() throws {
        try expectLocalized([
            "cli.simulator.error.tapInputsExclusive",
            "cli.simulator.error.tapSelectorRequired",
            "cli.simulator.error.tapTargetAmbiguous",
            "cli.simulator.error.tapTargetNotFound",
            "cli.simulator.error.uiDirectionInvalid",
            "cli.simulator.error.uiElementRefInvalid",
            "cli.simulator.error.uiElementRefNotFound",
            "cli.simulator.error.uiFocusUnavailable",
            "cli.simulator.error.uiGesturePresetInvalid",
            "cli.simulator.error.uiOperationInvalid",
            "cli.simulator.error.uiRoleInvalid",
            "cli.simulator.error.uiAutomationBusy",
            "cli.simulator.error.uiSnapshotDidNotSettle",
            "cli.simulator.error.uiSnapshotExpired",
            "cli.simulator.error.uiSnapshotMissing",
            "cli.simulator.error.uiSnapshotViewportMissing",
            "cli.simulator.error.uiStableSelectorUnavailable",
            "cli.simulator.error.uiStateChanged",
            "cli.simulator.error.uiTargetNotActionable",
            "cli.simulator.error.uiTextUnsupported",
            "cli.simulator.error.uiTouchAlreadyHeld",
            "cli.simulator.error.uiWaitPredicateInvalid",
            "cli.simulator.error.uiWaitTargetAmbiguous",
            "cli.simulator.error.uiWaitTimeout",
            "cli.simulator.output.uiSnapshotTruncated",
            "cli.simulator.output.uiSnapshotUnchanged",
            "cli.simulator.output.uiWaitMatched",
            "cli.simulator.recovery.captureSnapshot",
            "cli.simulator.recovery.chooseAdvertisedAction",
            "cli.simulator.recovery.releaseHeldTouch",
            "cli.simulator.recovery.refineWait",
            "cli.simulator.recovery.retryAfterActiveOperation",
            "cli.simulator.usage.automation",
            "cli.simulator.warning.uiSnapshotRefreshFailed",
            "simulator.control.privacyServiceUnavailable",
            "simulator.failure.accessibilityCapability",
            "simulator.failure.cameraAdapterCapability",
            "simulator.failure.foregroundCapability",
            "simulator.failure.permissionMutationCapability",
            "simulator.failure.permissionReadbackCapability",
            "simulator.failure.permissionResetAllCapability",
            "simulator.failure.webInspectorCapability",
        ], languages: [
            "ar", "bs", "da", "de", "en", "es", "fr", "it", "ja", "km",
            "ko", "nb", "pl", "pt-BR", "ru", "th", "tr", "uk", "zh-Hans",
            "zh-Hant",
        ])
    }

    private func expectLocalized(
        _ keys: [String],
        languages: [String]
    ) throws {
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
            for language in languages {
                let localization = localizations?[language] as? [String: Any]
                let stringUnit = localization?["stringUnit"] as? [String: Any]
                let value = stringUnit?["value"] as? String
                #expect(value?.isEmpty == false)
            }
        }
    }
}
