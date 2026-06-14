import Foundation

/// The per-gate status of the network / authentication / trust pairing
/// checklist. A value type so the whole "how far did pairing get" projection is
/// computed in one place and rendered as plain immutable data by the UI
/// (https://github.com/manaflow-ai/cmux/issues/6084).
public struct MobilePairingChecklist: Equatable, Sendable {
    /// Status of the network gate (reaching the Mac).
    public var network: MobilePairingStageStatus
    /// Status of the authentication gate (verifying this device's account).
    public var authentication: MobilePairingStageStatus
    /// Status of the trust gate (confirming it's the right Mac on a trusted route).
    public var trust: MobilePairingStageStatus

    /// Create a checklist from an explicit status for each gate.
    /// - Parameters:
    ///   - network: Status of the network gate.
    ///   - authentication: Status of the authentication gate.
    ///   - trust: Status of the trust gate.
    public init(
        network: MobilePairingStageStatus,
        authentication: MobilePairingStageStatus,
        trust: MobilePairingStageStatus
    ) {
        self.network = network
        self.authentication = authentication
        self.trust = trust
    }

    /// The status of a given gate.
    public func status(for stage: MobilePairingStage) -> MobilePairingStageStatus {
        switch stage {
        case .network: return network
        case .authentication: return authentication
        case .trust: return trust
        }
    }

    /// The gate that failed, if any (at most one gate fails per attempt).
    public var failedStage: MobilePairingStage? {
        MobilePairingStage.allCases.first { status(for: $0).isFailed }
    }

    /// True while an attempt is in flight and no gate has resolved yet.
    public var isInProgress: Bool {
        MobilePairingStage.allCases.contains { status(for: $0) == .inProgress }
    }

    /// The checklist while an attempt is in flight: the network gate is being
    /// attempted; the later gates wait their turn.
    public static let connecting = MobilePairingChecklist(
        network: .inProgress,
        authentication: .pending,
        trust: .pending
    )

    /// The checklist once every gate has cleared.
    public static let connected = MobilePairingChecklist(
        network: .succeeded,
        authentication: .succeeded,
        trust: .succeeded
    )
}
