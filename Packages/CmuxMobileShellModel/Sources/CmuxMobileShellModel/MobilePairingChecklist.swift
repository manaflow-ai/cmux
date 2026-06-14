import Foundation

/// One of the three discrete gates a pairing attempt must clear, in the order
/// they are attempted. Surfacing each as its own check mark lets the user tell
/// exactly which stage succeeded or failed instead of reading one opaque
/// "could not connect" (https://github.com/manaflow-ai/cmux/issues/6084).
public enum MobilePairingStage: Equatable, Sendable, CaseIterable {
    /// Reaching the Mac over the network: reachability, routing, the listener,
    /// and opening the transport to the address the pairing code points at. The
    /// first gate — nothing else can be attempted until it clears.
    case network
    /// Verifying this device's signed-in account credential with the Mac.
    case authentication
    /// Confirming the Mac belongs to the same cmux account, over a route trusted
    /// to carry that credential. The last gate.
    case trust

    /// Position in the attempt order, used to decide which gates an earlier
    /// failure leaves untested (`.pending`) versus provably cleared.
    public var order: Int {
        switch self {
        case .network: return 0
        case .authentication: return 1
        case .trust: return 2
        }
    }
}

/// The resolution state of a single pairing gate, mirrored into an individual
/// check mark in the pairing UI.
public enum MobilePairingStageStatus: Equatable, Sendable {
    /// Not started, or left untested because an earlier gate has not cleared.
    case pending
    /// Currently being attempted.
    case inProgress
    /// Cleared.
    case succeeded
    /// Failed, carrying the localized headline and optional actionable guidance
    /// the UI shows beneath this gate's row.
    case failed(message: String, guidance: String?)

    /// Whether this gate is the one that failed.
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The failure headline, when this gate failed.
    public var failureMessage: String? {
        if case let .failed(message, _) = self { return message }
        return nil
    }

    /// The actionable next-step line, when this gate failed and one applies.
    public var failureGuidance: String? {
        if case let .failed(_, guidance) = self { return guidance }
        return nil
    }
}

/// The per-gate status of the network / authentication / trust pairing
/// checklist. A value type so the whole "how far did pairing get" projection is
/// computed in one place and rendered as plain immutable data by the UI.
public struct MobilePairingChecklist: Equatable, Sendable {
    public var network: MobilePairingStageStatus
    public var authentication: MobilePairingStageStatus
    public var trust: MobilePairingStageStatus

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
