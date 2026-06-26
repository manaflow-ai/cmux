import Foundation

/// The render-ready network/authentication/trust checklist for pairing.
public struct MobilePairingChecklist: Equatable, Sendable {
    /// The network reachability row.
    public var network: MobilePairingStepSnapshot
    /// The account authentication row.
    public var authentication: MobilePairingStepSnapshot
    /// The trust row.
    public var trust: MobilePairingStepSnapshot

    /// The rows in display order.
    public var steps: [MobilePairingStepSnapshot] {
        [network, authentication, trust]
    }

    /// Whether any row currently has a failure state.
    public var hasFailure: Bool {
        steps.contains { $0.status == .failed }
    }

    /// Creates a pairing checklist from individual rows.
    ///
    /// - Parameters:
    ///   - network: The network reachability row.
    ///   - authentication: The account authentication row.
    ///   - trust: The trust row.
    public init(
        network: MobilePairingStepSnapshot,
        authentication: MobilePairingStepSnapshot,
        trust: MobilePairingStepSnapshot
    ) {
        self.network = network
        self.authentication = authentication
        self.trust = trust
    }

    /// A checklist before a pairing attempt has started.
    public static var idle: MobilePairingChecklist {
        MobilePairingChecklist(
            network: MobilePairingStepSnapshot(step: .network, status: .pending),
            authentication: MobilePairingStepSnapshot(step: .authentication, status: .pending),
            trust: MobilePairingStepSnapshot(step: .trust, status: .pending)
        )
    }

    /// A checklist while a pairing attempt is actively resolving.
    public static var inProgress: MobilePairingChecklist {
        MobilePairingChecklist(
            network: MobilePairingStepSnapshot(step: .network, status: .inProgress),
            authentication: MobilePairingStepSnapshot(step: .authentication, status: .inProgress),
            trust: MobilePairingStepSnapshot(step: .trust, status: .inProgress)
        )
    }

    /// A checklist after a pairing attempt succeeds.
    public static var succeeded: MobilePairingChecklist {
        MobilePairingChecklist(
            network: MobilePairingStepSnapshot(step: .network, status: .succeeded),
            authentication: MobilePairingStepSnapshot(step: .authentication, status: .succeeded),
            trust: MobilePairingStepSnapshot(step: .trust, status: .succeeded)
        )
    }

    /// Returns a copy with one row updated.
    ///
    /// - Parameters:
    ///   - step: The row to update.
    ///   - status: The new row state.
    ///   - message: The failure headline for the row.
    ///   - guidance: The shorter recovery suggestion for the row.
    /// - Returns: A checklist with the requested row changed.
    public func updating(
        _ step: MobilePairingStep,
        status: MobilePairingStepStatus,
        message: String? = nil,
        guidance: String? = nil
    ) -> MobilePairingChecklist {
        var copy = self
        copy.set(
            MobilePairingStepSnapshot(
                step: step,
                status: status,
                message: message,
                guidance: guidance
            )
        )
        return copy
    }

    /// Returns a terminal failure state for one row, preserving explicit successes.
    ///
    /// Rows listed in `succeededSteps` become green check marks, the failed row
    /// carries the actionable message, and any other in-progress rows return to
    /// pending so the user can see which gates were not reached.
    ///
    /// - Parameters:
    ///   - step: The row that failed.
    ///   - message: The failure headline for the row.
    ///   - guidance: The shorter recovery suggestion for the row.
    ///   - succeededSteps: Rows known to have succeeded before this failure.
    /// - Returns: A checklist with one failed row and any known successes.
    public func applyingFailure(
        _ step: MobilePairingStep,
        message: String,
        guidance: String? = nil,
        succeededSteps: Set<MobilePairingStep> = []
    ) -> MobilePairingChecklist {
        var copy = self
        for candidate in MobilePairingStep.allCases {
            if candidate == step {
                copy.set(
                    MobilePairingStepSnapshot(
                        step: candidate,
                        status: .failed,
                        message: message,
                        guidance: guidance
                    )
                )
            } else if succeededSteps.contains(candidate) || copy.snapshot(for: candidate).status == .succeeded {
                copy.set(MobilePairingStepSnapshot(step: candidate, status: .succeeded))
            } else {
                copy.set(MobilePairingStepSnapshot(step: candidate, status: .pending))
            }
        }
        return copy
    }

    private func snapshot(for step: MobilePairingStep) -> MobilePairingStepSnapshot {
        switch step {
        case .network:
            return network
        case .authentication:
            return authentication
        case .trust:
            return trust
        }
    }

    private mutating func set(_ snapshot: MobilePairingStepSnapshot) {
        switch snapshot.step {
        case .network:
            network = snapshot
        case .authentication:
            authentication = snapshot
        case .trust:
            trust = snapshot
        }
    }
}
