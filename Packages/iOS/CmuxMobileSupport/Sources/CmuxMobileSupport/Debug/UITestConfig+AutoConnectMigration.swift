#if DEBUG
import Foundation

/// An isolated Auto-Connect migration state requested by an XCUITest launch.
public struct AutoConnectMigrationUITestConfiguration: Equatable, Sendable {
    /// The eligibility snapshot the test launch should begin with.
    public enum Eligibility: String, Equatable, Sendable {
        case eligible
        case ineligible
    }

    /// A connection-method value already persisted by the upgraded install.
    public enum PersistedConnectionMethod: String, Equatable, Sendable {
        /// The built-in encrypted transport was selected.
        case automatic
        /// Tailscale-only transport was selected.
        case tailscale
        /// An unrecognized future or corrupt raw value was persisted.
        case unknown
    }

    /// A resolution persisted by the prior v1 introduction.
    public enum LegacyResolution: String, Equatable, Sendable {
        /// The prior introduction had not been resolved.
        case pending
        /// The install did not qualify for the prior introduction.
        case ineligible
        /// The prior introduction was explicitly resolved.
        case acknowledged
    }

    /// A real modal host that should own presentation before migration checks.
    public enum InitialModalHost: String, Equatable, Sendable {
        case rootPairing = "root-pairing"
        case workspaceListDeviceTree = "workspace-list-device-tree"
        case workspaceDetailTerminalText = "workspace-detail-terminal-text"
    }

    /// A launch prerequisite held unavailable for deterministic suppression tests.
    public enum ReadinessGate: String, Equatable, Sendable {
        case authenticationRestoring = "authentication-restoring"
        case sceneInactive = "scene-inactive"
        case explicitAttachRoute = "explicit-attach-route"
    }

    /// The eligibility prerequisites seeded into this fixture's isolated suite.
    public let eligibility: Eligibility
    /// A per-test identifier used to isolate all migration-owned defaults.
    public let identifier: String
    /// Whether Settings should own the root modal slot before migration
    /// eligibility is checked.
    public let presentsShellSettingsBeforeMigration: Bool
    /// The real modal host that initially owns the shared presentation slot.
    public let initialModalHost: InitialModalHost?
    /// The launch prerequisite held unavailable until the next fixture launch.
    public let readinessGate: ReadinessGate?
    /// The connection method present before the corrected migration snapshots.
    public let persistedConnectionMethod: PersistedConnectionMethod?
    /// The v1 introduction outcome present before the corrected migration snapshots.
    public let legacyResolution: LegacyResolution?
    /// Whether this launch exposes a leaf viewport probe for XCUITest geometry.
    public let showsLayoutProbe: Bool

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
        self.presentsShellSettingsBeforeMigration =
            environment["CMUX_UITEST_AUTOCONNECT_MIGRATION_INITIAL_SETTINGS"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        if let rawInitialModalHost = environment[
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_INITIAL_MODAL_HOST"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawInitialModalHost.isEmpty {
            guard let initialModalHost = InitialModalHost(rawValue: rawInitialModalHost) else {
                return nil
            }
            self.initialModalHost = initialModalHost
        } else {
            self.initialModalHost = nil
        }
        if let rawReadinessGate = environment[
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_READINESS_GATE"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawReadinessGate.isEmpty {
            guard let readinessGate = ReadinessGate(rawValue: rawReadinessGate) else {
                return nil
            }
            self.readinessGate = readinessGate
        } else {
            self.readinessGate = nil
        }
        if let rawPersistedConnectionMethod = environment[
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_PERSISTED_METHOD"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPersistedConnectionMethod.isEmpty {
            guard let persistedConnectionMethod = PersistedConnectionMethod(
                rawValue: rawPersistedConnectionMethod
            ) else {
                return nil
            }
            self.persistedConnectionMethod = persistedConnectionMethod
        } else {
            self.persistedConnectionMethod = nil
        }
        if let rawLegacyResolution = environment[
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_V1_RESOLUTION"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawLegacyResolution.isEmpty {
            guard let legacyResolution = LegacyResolution(rawValue: rawLegacyResolution) else {
                return nil
            }
            self.legacyResolution = legacyResolution
        } else {
            self.legacyResolution = nil
        }
        self.showsLayoutProbe =
            environment["CMUX_UITEST_AUTOCONNECT_MIGRATION_LAYOUT_PROBES"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// The fixture requested by the current DEBUG process, when valid.
    public static var currentProcess: AutoConnectMigrationUITestConfiguration? {
        AutoConnectMigrationUITestConfiguration(
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// A stable suite shared across relaunches of one UI-test fixture.
    public var defaultsSuiteName: String {
        "dev.cmux.uitest.autoConnectMigration.\(identifier)"
    }
}
#endif
