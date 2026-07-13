import CmuxMobileShell
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct MobileMacUpdateHintDisplayTests {
    @Test func everyFeatureHasADisplayName() {
        for feature in MobileMacUpdateFeature.allCases {
            #expect(!feature.displayName.isEmpty)
        }
    }

    @Test func bodyTextIncludesMacVersionsAndEveryFeature() throws {
        let requirements = MobileMacUpdateFeature.allCases.enumerated().map { index, feature in
            MobileMacUpdateCapabilityRequirement(
                capability: "test.capability.\(index)",
                feature: feature,
                firstReleasedMacVersion: MobileMacAppVersion(parsing: "0.64.16")
            )
        }
        let hint = try #require(MobileMacUpdateHint(
            hostCapabilities: [],
            macAppVersion: "0.64.15",
            requirements: requirements
        ))

        let body = hint.bodyText(macName: "Studio Mac")

        #expect(body.contains("Studio Mac"))
        #expect(body.contains("0.64.15"))
        #expect(body.contains("0.64.16"))
        for feature in MobileMacUpdateFeature.allCases {
            #expect(body.contains(feature.displayName))
        }
    }

    @Test func bodyTextForInferredVersionNamesOnlyTheTargetVersion() throws {
        let requirements = [
            MobileMacUpdateCapabilityRequirement(
                capability: "test.present",
                feature: .workspaceActions,
                firstReleasedMacVersion: MobileMacAppVersion(parsing: "0.64.15")
            ),
            MobileMacUpdateCapabilityRequirement(
                capability: "test.missing",
                feature: .workspaceGroups,
                firstReleasedMacVersion: MobileMacAppVersion(parsing: "0.64.16")
            ),
        ]
        let hint = try #require(MobileMacUpdateHint(
            hostCapabilities: ["test.present"],
            macAppVersion: nil,
            requirements: requirements
        ))
        #expect(hint.isVersionInferred)

        let body = hint.bodyText(macName: "Studio Mac")

        #expect(body.contains("Studio Mac"))
        #expect(body.contains("0.64.16"))
        // The inferred current version must not be presented as fact.
        #expect(!body.contains("0.64.15"))
    }
}
