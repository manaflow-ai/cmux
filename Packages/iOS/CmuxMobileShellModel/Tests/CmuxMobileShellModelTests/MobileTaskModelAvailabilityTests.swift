import Foundation
import Testing
@testable import CmuxMobileShellModel

@Suite("Mobile task model availability")
struct MobileTaskModelAvailabilityTests {
    private let template = MobileTaskTemplate(
        id: UUID(),
        name: "Codex",
        icon: "terminal",
        command: "codex"
    )

    @Test func discoveredModelsDriveDisplayAndValidation() {
        let discovered = [
            MobileTaskAgentModel(id: "gpt-private", displayName: "gpt-private"),
        ]
        let availability = MobileTaskModelAvailability(
            template: template,
            discoveredModels: discovered
        )

        #expect(availability.models == discovered)
        #expect(availability.validatedModelID("gpt-private") == "gpt-private")
        #expect(availability.validatedModelID("gpt-5.6-sol") == nil)
    }

    @Test func missingDiscoveryDoesNotInventModelsOnDevice() {
        let availability = MobileTaskModelAvailability(
            template: template,
            discoveredModels: nil
        )

        #expect(availability.models.isEmpty)
        #expect(availability.validatedModelID("gpt-5.6-sol") == nil)
        #expect(availability.validatedModelID("unknown") == nil)
    }

    @Test func previouslyValidDraftSelectionSurvivesDelistingWithRawName() {
        let refreshed = MobileTaskModelAvailability(
            template: template,
            discoveredModels: [
                MobileTaskAgentModel(id: "new-model", displayName: "New Model"),
            ]
        )

        let restored = refreshed.validatedModelID(
            "delisted-model",
            previouslyValidModelID: "delisted-model"
        )
        #expect(restored == "delisted-model")
        #expect(
            refreshed.selectedModel(id: restored)
                == MobileTaskAgentModel(
                    id: "delisted-model",
                    displayName: "delisted-model"
                )
        )
    }

    @Test func previouslyValidDraftSelectionSurvivesColdCatalog() {
        let coldAvailability = MobileTaskModelAvailability(
            template: template,
            discoveredModels: nil
        )

        let restored = coldAvailability.validatedModelID(
            "persisted-agent-model",
            previouslyValidModelID: "persisted-agent-model"
        )

        #expect(restored == "persisted-agent-model")
        #expect(
            coldAvailability.selectedModel(id: restored)
                == MobileTaskAgentModel(
                    id: "persisted-agent-model",
                    displayName: "persisted-agent-model"
                )
        )
    }
}
