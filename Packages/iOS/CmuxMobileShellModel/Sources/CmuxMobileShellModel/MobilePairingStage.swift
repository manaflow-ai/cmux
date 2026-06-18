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
