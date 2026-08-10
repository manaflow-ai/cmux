#if DEBUG
import Foundation

/// An isolated Auto-Connect migration state requested by an XCUITest launch.
public struct AutoConnectMigrationUITestConfiguration: Equatable, Sendable {
    /// The eligibility snapshot the test launch should begin with.
    public enum Eligibility: String, Equatable, Sendable {
        case eligible
        case ineligible
    }

    /// The forced eligibility used only by the DEBUG composition root.
    public let eligibility: Eligibility
    /// A per-test identifier used to isolate persisted resolution across runs.
    public let identifier: String
}

public extension UITestConfig {
    /// The deterministic Auto-Connect migration launch fixture, when requested.
    static var autoConnectMigrationConfiguration: AutoConnectMigrationUITestConfiguration? {
        autoConnectMigrationConfiguration(from: ProcessInfo.processInfo.environment)
    }

    /// Parses a DEBUG-only migration fixture from explicit process inputs.
    ///
    /// Both a recognized eligibility and a non-empty test identifier are
    /// required. The mock-data gate prevents normal dogfood launches from
    /// accidentally replacing production eligibility.
    static func autoConnectMigrationConfiguration(
        from environment: [String: String]
    ) -> AutoConnectMigrationUITestConfiguration? {
        guard mockDataEnabled(from: environment),
              let rawEligibility = environment["CMUX_UITEST_AUTOCONNECT_MIGRATION"],
              let eligibility = AutoConnectMigrationUITestConfiguration.Eligibility(
                rawValue: rawEligibility.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              let identifier = environment["CMUX_UITEST_AUTOCONNECT_MIGRATION_ID"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return nil
        }
        return AutoConnectMigrationUITestConfiguration(
            eligibility: eligibility,
            identifier: identifier
        )
    }
}
#endif
