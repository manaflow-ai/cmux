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

    @Test("Accessibility tap copy uses the touch action in every affected locale")
    func accessibilityTapCopyUsesTouchLanguage() throws {
        let expected = [
            "ar": "يتطلب النقر عبر إمكانية الوصول تسمية أو معرّفًا",
            "bs": "Dodir pristupačnosti zahtijeva oznaku ili identifikator",
            "da": "Et tilgængelighedstryk kræver en etiket eller identifikator",
            "de": "Für ein Tippen per Bedienungshilfe ist eine Beschriftung oder Kennung erforderlich",
            "es": "Un toque de accesibilidad requiere una etiqueta o un identificador",
            "fr": "Un toucher d’accessibilité nécessite une étiquette ou un identifiant",
            "pt-BR": "Um toque de acessibilidade requer um rótulo ou identificador",
            "uk": "Для дотику через функції доступності потрібна мітка або ідентифікатор",
            "zh-Hans": "辅助功能轻点需要标签或标识符",
            "zh-Hant": "輔助功能點按需要標籤或識別符",
        ]

        for (language, value) in expected {
            #expect(try localizedValue(
                key: "cli.simulator.error.tapSelectorRequired",
                language: language
            ) == value)
        }
        #expect(try localizedValue(
            key: "cli.simulator.error.tapInputsExclusive",
            language: "fr"
        ) == "Les coordonnées de toucher et les sélecteurs d’accessibilité s’excluent mutuellement")
    }

    @Test("Ambiguous tap recovery preserves literal CLI flags")
    func ambiguousTapRecoveryPreservesLiteralFlags() throws {
        let languages = [
            "ar", "bs", "da", "de", "en", "es", "fr", "it", "ja", "km",
            "ko", "nb", "pl", "pt-BR", "ru", "th", "tr", "uk", "zh-Hans",
            "zh-Hant",
        ]

        for language in languages {
            let value = try localizedValue(
                key: "cli.simulator.error.tapTargetAmbiguous",
                language: language
            )
            #expect(value.contains("--identifier"))
            #expect(value.contains("--role"))
        }
    }

    private func expectLocalized(
        _ keys: [String],
        languages: [String]
    ) throws {
        let strings = try catalogStrings()

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

    private func localizedValue(
        key: String,
        language: String
    ) throws -> String {
        let strings = try catalogStrings()
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let localization = try #require(localizations[language] as? [String: Any])
        let stringUnit = try #require(localization["stringUnit"] as? [String: Any])
        return try #require(stringUnit["value"] as? String)
    }

    private func catalogStrings() throws -> [String: Any] {
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
        return try #require(catalog["strings"] as? [String: Any])
    }
}
