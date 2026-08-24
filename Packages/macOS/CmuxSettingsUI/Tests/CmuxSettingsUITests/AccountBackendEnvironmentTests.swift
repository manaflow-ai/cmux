import Testing
@testable import CmuxSettingsUI

/// The package-local backend environment enum mirrors the host's explicit
/// choice; these tests pin the contract the host mapping relies on.
@Suite("AccountBackendEnvironment")
struct AccountBackendEnvironmentTests {
    @Test func productionAndStagingAreTheOnlyCasesWithProductionFirst() {
        #expect(AccountBackendEnvironment.allCases == [.production, .staging])
    }

    @Test func rawValuesMatchTheHostOverrideStorageValues() {
        #expect(AccountBackendEnvironment.production.rawValue == "production")
        #expect(AccountBackendEnvironment.staging.rawValue == "staging")
        #expect(AccountBackendEnvironment(rawValue: "production") == .production)
        #expect(AccountBackendEnvironment(rawValue: "staging") == .staging)
    }

    @Test func displayNamesAreNonEmptyAndDistinct() {
        #expect(!AccountBackendEnvironment.production.displayName.isEmpty)
        #expect(!AccountBackendEnvironment.staging.displayName.isEmpty)
        #expect(
            AccountBackendEnvironment.production.displayName
                != AccountBackendEnvironment.staging.displayName
        )
    }
}

/// The build-lane mirror and the picker's option-set rule.
@Suite("AccountBackendEnvironmentBuildLane")
struct AccountBackendEnvironmentBuildLaneTests {
    @Test func lanesResolveStagingOnlyForTheStagingLane() {
        #expect(AccountBackendEnvironmentBuildLane.production.resolvedEnvironment == .production)
        #expect(AccountBackendEnvironmentBuildLane.staging.resolvedEnvironment == .staging)
        #expect(
            AccountBackendEnvironmentBuildLane.custom(label: "localhost:4123")
                .resolvedEnvironment == .production
        )
    }

    @Test func laneLabelsNameTheLane() {
        #expect(
            AccountBackendEnvironmentBuildLane.production.label
                == AccountBackendEnvironment.production.displayName
        )
        #expect(
            AccountBackendEnvironmentBuildLane.staging.label
                == AccountBackendEnvironment.staging.displayName
        )
        #expect(
            AccountBackendEnvironmentBuildLane.custom(label: "localhost:4123").label
                == "localhost:4123"
        )
    }
}

/// The selection mirror: the picker's option-set rule and resolution.
@Suite("AccountBackendEnvironmentSelection")
struct AccountBackendEnvironmentSelectionTests {
    @Test func productionLaneKeepsTheTwoPositionPicker() {
        // The option-set rule: production-lane builds see exactly today's
        // Production/Staging pair — no "Build lane" option, because the host
        // maps "Production" back to the lane (clearChoice).
        #expect(
            AccountBackendEnvironmentSelection.pickerOptions(for: .production)
                == [.production, .staging]
        )
    }

    @Test func nonProductionLanesGetTheThreePositionPicker() {
        #expect(
            AccountBackendEnvironmentSelection.pickerOptions(for: .staging)
                == [.buildLane, .production, .staging]
        )
        #expect(
            AccountBackendEnvironmentSelection.pickerOptions(
                for: .custom(label: "localhost:4123")
            ) == [.buildLane, .production, .staging]
        )
    }

    @Test func selectionsResolveAgainstTheLane() {
        #expect(
            AccountBackendEnvironmentSelection.buildLane
                .resolvedEnvironment(lane: .staging) == .staging
        )
        #expect(
            AccountBackendEnvironmentSelection.buildLane
                .resolvedEnvironment(lane: .production) == .production
        )
        #expect(
            AccountBackendEnvironmentSelection.buildLane
                .resolvedEnvironment(lane: .custom(label: "x")) == .production
        )
        #expect(
            AccountBackendEnvironmentSelection.production
                .resolvedEnvironment(lane: .staging) == .production
        )
        #expect(
            AccountBackendEnvironmentSelection.staging
                .resolvedEnvironment(lane: .production) == .staging
        )
    }

    @Test func displayNamesDistinguishTheLaneOptionFromExplicitChoices() {
        let laneName = AccountBackendEnvironmentSelection.buildLane
            .displayName(lane: .custom(label: "localhost:4123"))
        #expect(laneName.contains("localhost:4123"))
        #expect(
            AccountBackendEnvironmentSelection.production.displayName(lane: .staging)
                == AccountBackendEnvironment.production.displayName
        )
        #expect(
            AccountBackendEnvironmentSelection.staging.displayName(lane: .production)
                == AccountBackendEnvironment.staging.displayName
        )
        #expect(laneName != AccountBackendEnvironment.staging.displayName)
    }
}
