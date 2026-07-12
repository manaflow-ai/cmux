import CmuxMobileShell
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct MobileMacUpdateFeatureDisplayTests {
    @Test func everyFeatureHasADisplayName() {
        for feature in MobileMacUpdateFeature.allCases {
            #expect(!MobileMacUpdateFeatureDisplay.name(for: feature).isEmpty)
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
        let hint = try #require(MobileMacUpdateAdvisor.hint(
            hostCapabilities: [],
            macAppVersion: "0.64.15",
            requirements: requirements
        ))

        let body = MobileMacUpdateHintBanner.bodyText(hint: hint, macName: "Studio Mac")

        #expect(body.contains("Studio Mac"))
        #expect(body.contains("0.64.15"))
        #expect(body.contains("0.64.16"))
        for feature in MobileMacUpdateFeature.allCases {
            #expect(body.contains(MobileMacUpdateFeatureDisplay.name(for: feature)))
        }
    }
}
