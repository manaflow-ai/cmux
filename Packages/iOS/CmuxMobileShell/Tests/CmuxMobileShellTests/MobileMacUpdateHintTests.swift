import CmuxMobileShell
import Testing

@Suite
struct MobileMacUpdateHintTests {
    private let requirements: [MobileMacUpdateCapabilityRequirement] = [
        .init(capability: "released.early", feature: .workspaceActions, firstReleasedMacVersion: .init(parsing: "2.0")),
        .init(capability: "released.late", feature: .workspaceGroups, firstReleasedMacVersion: .init(parsing: "3.0")),
        .init(capability: "unreleased", feature: .workspaceMove, firstReleasedMacVersion: nil),
    ]

    @Test
    func olderVersionAndMissingReleasedCapabilityProducesHint() throws {
        let hint = try #require(MobileMacUpdateHint(
            hostCapabilities: ["released.late", "unreleased"],
            macAppVersion: "1.5",
            requirements: requirements
        ))

        #expect(hint.features == [.workspaceActions])
        #expect(hint.minimumMacVersion == MobileMacAppVersion(parsing: "2.0"))
        #expect(hint.macAppVersion == MobileMacAppVersion(parsing: "1.5"))
    }

    @Test(arguments: ["2.0", "2.1"])
    func currentOrNewerVersionDoesNotProduceHint(version: String) {
        let hint = MobileMacUpdateHint(
            hostCapabilities: ["released.late", "unreleased"],
            macAppVersion: version,
            requirements: requirements
        )
        #expect(hint == nil)
    }

    @Test(arguments: [nil, "unknown", "2.0-nightly"] as [String?])
    func absentOrUnparseableVersionDoesNotProduceHint(version: String?) {
        #expect(MobileMacUpdateHint(
            hostCapabilities: [],
            macAppVersion: version,
            requirements: requirements
        ) == nil)
    }

    @Test
    func absentVersionInfersFromAdvertisedRegisteredCapabilities() throws {
        let hint = try #require(MobileMacUpdateHint(
            hostCapabilities: ["released.early"],
            macAppVersion: nil,
            requirements: requirements
        ))

        #expect(hint.features == [.workspaceGroups])
        #expect(hint.minimumMacVersion == MobileMacAppVersion(parsing: "3.0"))
        #expect(hint.macAppVersion == MobileMacAppVersion(parsing: "2.0"))
        #expect(hint.isVersionInferred)
    }

    @Test
    func absentVersionWithoutRegisteredCapabilitiesStaysSilent() {
        #expect(MobileMacUpdateHint(
            hostCapabilities: ["unreleased", "unregistered.cap"],
            macAppVersion: nil,
            requirements: requirements
        ) == nil)
    }

    @Test
    func explicitVersionIsNotInferredAndWinsOverCapabilityInference() throws {
        let hint = try #require(MobileMacUpdateHint(
            hostCapabilities: ["released.early"],
            macAppVersion: "2.5",
            requirements: requirements
        ))

        #expect(hint.macAppVersion == MobileMacAppVersion(parsing: "2.5"))
        #expect(!hint.isVersionInferred)
    }

    @Test
    func unparseableVersionSuppressesCapabilityInference() {
        #expect(MobileMacUpdateHint(
            hostCapabilities: ["released.early"],
            macAppVersion: "2.0-nightly",
            requirements: requirements
        ) == nil)
    }

    @Test
    func standardRegistryInfersLegacyMacFromActionsCapability() throws {
        // The production case the registry targets: a released 0.64.15 Mac
        // predates both version fields, so it reports no version at all but
        // does advertise workspace.actions.v1.
        let hint = try #require(MobileMacUpdateHint(
            hostCapabilities: ["workspace.actions.v1", "terminal.bytes.v1"],
            macAppVersion: nil
        ))

        #expect(hint.features == [.workspaceReadState, .workspaceClose, .workspaceGroups])
        #expect(hint.minimumMacVersion == MobileMacAppVersion(parsing: "0.64.16"))
        #expect(hint.isVersionInferred)
    }

    @Test
    func missingUnreleasedCapabilityDoesNotProduceHint() {
        #expect(MobileMacUpdateHint(
            hostCapabilities: ["released.early", "released.late"],
            macAppVersion: "1.0",
            requirements: requirements
        ) == nil)
    }

    @Test
    func mixedReleasedAndUnreleasedGapsIncludesOnlyReleasedFeaturesAtMaximumVersion() throws {
        let hint = try #require(MobileMacUpdateHint(
            hostCapabilities: [],
            macAppVersion: "1.0",
            requirements: requirements
        ))

        #expect(hint.features == [.workspaceActions, .workspaceGroups])
        #expect(hint.minimumMacVersion == MobileMacAppVersion(parsing: "3.0"))
    }

    @Test
    func allCapabilitiesPresentDoesNotProduceHint() {
        #expect(MobileMacUpdateHint(
            hostCapabilities: ["released.early", "released.late", "unreleased"],
            macAppVersion: "1.0",
            requirements: requirements
        ) == nil)
    }

    @Test
    func emptyCapabilitySetAndOldVersionIncludesAllReleasedFeatures() throws {
        let hint = try #require(MobileMacUpdateHint(
            hostCapabilities: [],
            macAppVersion: "1.0",
            requirements: requirements
        ))
        #expect(hint.features == [.workspaceActions, .workspaceGroups])
    }

    @Test
    func duplicateFeatureRequirementsRemainUniqueInRegistryOrder() throws {
        let duplicateRequirements = requirements + [
            .init(capability: "released.duplicate", feature: .workspaceActions, firstReleasedMacVersion: .init(parsing: "2.5")),
        ]
        let hint = try #require(MobileMacUpdateHint(
            hostCapabilities: [],
            macAppVersion: "1.0",
            requirements: duplicateRequirements
        ))
        #expect(hint.features == [.workspaceActions, .workspaceGroups])
    }

    @Test
    func dismissalSignatureIsStableAndChangesWithGapOrMinimumVersion() throws {
        let reordered = [requirements[1], requirements[0], requirements[2]]
        let first = try #require(MobileMacUpdateHint(
            hostCapabilities: [],
            macAppVersion: "1.0",
            requirements: requirements
        ))
        let second = try #require(MobileMacUpdateHint(
            hostCapabilities: [],
            macAppVersion: "1.0",
            requirements: reordered
        ))
        let changedGap = try #require(MobileMacUpdateHint(
            hostCapabilities: ["released.early"],
            macAppVersion: "1.0",
            requirements: requirements
        ))
        let changedMinimumRequirements = requirements.map { requirement in
            requirement.capability == "released.late"
                ? .init(capability: requirement.capability, feature: requirement.feature, firstReleasedMacVersion: .init(parsing: "4.0"))
                : requirement
        }
        let changedMinimum = try #require(MobileMacUpdateHint(
            hostCapabilities: [],
            macAppVersion: "1.0",
            requirements: changedMinimumRequirements
        ))

        #expect(first.dismissalSignature == second.dismissalSignature)
        #expect(first.dismissalSignature != changedGap.dismissalSignature)
        #expect(first.dismissalSignature != changedMinimum.dismissalSignature)
    }

    @Test
    func standardRegistryReportsOnlyMissingGroupsCapability() throws {
        let capabilities = Set(MobileMacUpdateCapabilityRequirement.standard.map(\.capability))
            .subtracting(["workspace.groups.v1"])
        let hint = try #require(MobileMacUpdateHint(
            hostCapabilities: capabilities,
            macAppVersion: "0.64.15"
        ))

        #expect(hint.features == [.workspaceGroups])
        #expect(hint.minimumMacVersion == MobileMacAppVersion(parsing: "0.64.16"))
    }
}
