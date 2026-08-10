#if DEBUG
import Foundation

/// An isolated Auto-Connect migration state requested by an XCUITest launch.
public struct AutoConnectMigrationUITestConfiguration: Equatable, Sendable {
    /// The eligibility snapshot the test launch should begin with.
    public enum Eligibility: String, Equatable, Sendable {
        case eligible
        case ineligible
    }

    /// The eligibility prerequisites seeded into this fixture's isolated suite.
    public let eligibility: Eligibility
    /// A per-test identifier used to isolate all migration-owned defaults.
    public let identifier: String
    /// Whether Settings should own the root modal slot before migration
    /// eligibility is checked.
    public let presentsWorkspaceSettingsBeforeMigration: Bool

    /// Parses a DEBUG-only migration fixture from explicit process inputs.
    ///
    /// Both a recognized eligibility and a non-empty test identifier are
    /// required. The mock-data gate prevents normal dogfood launches from
    /// accidentally replacing production eligibility.
    public init?(environment: [String: String]) {
        guard UITestConfig.mockDataEnabled(from: environment),
              let rawEligibility = environment["CMUX_UITEST_AUTOCONNECT_MIGRATION"],
              let eligibility = Eligibility(
                rawValue: rawEligibility.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              let identifier = environment["CMUX_UITEST_AUTOCONNECT_MIGRATION_ID"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return nil
        }
        self.eligibility = eligibility
        self.identifier = identifier
        self.presentsWorkspaceSettingsBeforeMigration =
            environment["CMUX_UITEST_AUTOCONNECT_MIGRATION_INITIAL_SETTINGS"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// A stable suite shared across relaunches of one UI-test fixture.
    public var defaultsSuiteName: String {
        "dev.cmux.uitest.autoConnectMigration.\(identifier)"
    }
}
#endif
