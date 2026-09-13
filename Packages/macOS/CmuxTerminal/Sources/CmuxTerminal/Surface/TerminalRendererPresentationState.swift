import Foundation

/// The identity and geometry that one acknowledged frame can prove.
struct TerminalRendererPresentationTarget: Equatable, Sendable {
    let runtimeGeneration: UInt64
    let portalGeneration: UInt64
    let host: ObjectIdentifier?
    let hostInstance: UInt64?
    let window: ObjectIdentifier?
    let nativeWindow: ObjectIdentifier?
    let layer: ObjectIdentifier?
    let paneFrame: CGRect
    let nativeFrame: CGRect
    let backingScale: CGFloat
    let contentRevision: UInt64
}

/// Separates native request ownership from the validity of its result.
/// A hidden or moved pane invalidates proof, but keeps its pending request
/// until Ghostty acknowledges it. Only runtime retirement releases that lease.
final class TerminalRendererPresentationState {
    struct Probe: Sendable {
        let token: UInt64
        let epoch: UInt64
        let target: TerminalRendererPresentationTarget
    }

    private var token: UInt64 = 0
    private(set) var epoch: UInt64 = 0
    private(set) var inFlight: Probe?
    private(set) var acknowledged: Probe?
    private var recoveryTarget: TerminalRendererPresentationTarget?
    var contentRevision: UInt64 = 0
    var onManualOutputPresented: (@MainActor (UInt64) -> Void)?

    var inFlightToken: UInt64? { inFlight?.token }
    var recoveryAttempted: Bool { recoveryTarget != nil }

    func invalidate() {
        epoch &+= 1
        acknowledged = nil
        recoveryTarget = nil
    }

    func resetRuntime() {
        invalidate()
        inFlight = nil
    }

    func begin(target: TerminalRendererPresentationTarget) -> Probe? {
        guard inFlight == nil else { return nil }
        token &+= 1
        let probe = Probe(token: token, epoch: epoch, target: target)
        inFlight = probe
        return probe
    }

    func take(token: UInt64) -> Probe? {
        guard let probe = inFlight, probe.token == token else { return nil }
        inFlight = nil
        return probe
    }

    func isCurrent(_ probe: Probe, target: TerminalRendererPresentationTarget) -> Bool {
        probe.epoch == epoch && probe.target == target
    }

    func isPresented(target: TerminalRendererPresentationTarget) -> Bool {
        acknowledged.map { isCurrent($0, target: target) } ?? false
    }

    func acknowledge(_ probe: Probe) {
        acknowledged = probe
        recoveryTarget = nil
    }

    func recoveryWasAttempted(for target: TerminalRendererPresentationTarget) -> Bool {
        recoveryTarget == target
    }

    func beginRecovery(for target: TerminalRendererPresentationTarget) -> Bool {
        guard recoveryTarget != target else { return false }
        recoveryTarget = target
        acknowledged = nil
        return true
    }
}
