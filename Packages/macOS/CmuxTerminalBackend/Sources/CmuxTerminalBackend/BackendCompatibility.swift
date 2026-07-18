internal import Foundation

/// The negotiated authority of one identified backend connection.
///
/// Read-only connections stay alive for diagnostics and only the observational
/// commands supported by their negotiated protocol and advertised capabilities.
/// They never authorize PTY, topology, presentation, projection, or renderer
/// mutations.
public enum BackendCompatibilityResult: Equatable, Sendable {
    case readWrite(BackendReadWriteCompatibility)
    case readOnly(BackendReadOnlyCompatibility)

    /// The mutually supported protocol selected for this connection, if any.
    public var negotiatedProtocol: UInt32? {
        switch self {
        case .readWrite(let compatibility): compatibility.negotiatedProtocol
        case .readOnly(let compatibility): compatibility.negotiatedProtocol
        }
    }

    /// The read-only diagnostic when mutation authority was not negotiated.
    public var readOnlyDiagnostic: BackendReadOnlyCompatibility? {
        guard case .readOnly(let diagnostic) = self else { return nil }
        return diagnostic
    }
}

/// Successful protocol-v9 mutation negotiation.
public struct BackendReadWriteCompatibility: Equatable, Sendable {
    public let clientProtocolRange: ClosedRange<UInt32>
    public let serverProtocolRange: ClosedRange<UInt32>
    public let negotiatedProtocol: UInt32
    public let requiredCapabilities: Set<String>

    public init(
        clientProtocolRange: ClosedRange<UInt32>,
        serverProtocolRange: ClosedRange<UInt32>,
        negotiatedProtocol: UInt32,
        requiredCapabilities: Set<String>
    ) {
        self.clientProtocolRange = clientProtocolRange
        self.serverProtocolRange = serverProtocolRange
        self.negotiatedProtocol = negotiatedProtocol
        self.requiredCapabilities = requiredCapabilities
    }
}

/// Why an identified backend remains connected without mutation authority.
public enum BackendReadOnlyReason: String, Equatable, Hashable, Sendable {
    case incompatibleProtocol
    case protocolTooOld
    case missingCapabilities
}

/// Action metadata suitable for an upgrade banner or diagnostic surface.
public enum BackendCompatibilityUpgradeAction: String, Equatable, Sendable {
    case updateCmux

    /// Stable command identifier for routing the action in a host UI.
    public var identifier: String { "terminal-backend.update-cmux" }

    /// Localized action title. The app catalog supplies English and Japanese.
    public var localizedTitle: String {
        String(
            localized: "terminalBackend.compatibility.updateAction",
            defaultValue: "Update cmux to enable terminal controls"
        )
    }
}

/// Complete compatibility diagnostic retained on a read-only connection.
public struct BackendReadOnlyCompatibility: Equatable, Sendable {
    public let clientProtocolRange: ClosedRange<UInt32>
    public let serverProtocolRange: ClosedRange<UInt32>
    public let negotiatedProtocol: UInt32?
    public let minimumReadWriteProtocol: UInt32
    public let requiredCapabilities: Set<String>
    public let missingCapabilities: Set<String>
    public let reasons: Set<BackendReadOnlyReason>
    public let upgradeAction: BackendCompatibilityUpgradeAction

    public init(
        clientProtocolRange: ClosedRange<UInt32>,
        serverProtocolRange: ClosedRange<UInt32>,
        negotiatedProtocol: UInt32?,
        minimumReadWriteProtocol: UInt32,
        requiredCapabilities: Set<String>,
        missingCapabilities: Set<String>,
        reasons: Set<BackendReadOnlyReason>,
        upgradeAction: BackendCompatibilityUpgradeAction = .updateCmux
    ) {
        self.clientProtocolRange = clientProtocolRange
        self.serverProtocolRange = serverProtocolRange
        self.negotiatedProtocol = negotiatedProtocol
        self.minimumReadWriteProtocol = minimumReadWriteProtocol
        self.requiredCapabilities = requiredCapabilities
        self.missingCapabilities = missingCapabilities
        self.reasons = reasons
        self.upgradeAction = upgradeAction
    }
}
