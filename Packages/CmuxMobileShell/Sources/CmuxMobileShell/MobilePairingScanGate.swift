public import CMUXMobileCore
import Foundation

/// What a freshly scanned/pasted pairing code should do given the current
/// connection context.
public enum MobilePairingScanDisposition: Equatable, Sendable {
    /// Run the full pairing attempt (the normal path).
    case proceed
    /// The code belongs to the Mac this device is already connected to: keep
    /// the live session and show the ``MobilePairingFailureCategory/alreadyPaired(macName:)`` notice.
    case alreadyConnected(macName: String?)
    /// The code could not be decoded while a live session exists: keep the
    /// session and surface the classified category as a notice instead of
    /// tearing the connection down for a code that was never going to connect.
    case rejectKeepingConnection(MobilePairingFailureCategory)
}

/// Pure policy deciding the disposition of a scanned pairing code before the
/// composite claims a pairing attempt (which cancels the live connection's
/// tasks and resets the connection generation).
///
/// This is the guard that makes "scan a code while connected" safe: the
/// decode runs first (it is pure), and only a decodable code for a *different*
/// Mac is allowed to proceed into the destructive re-pair path.
public struct MobilePairingScanGate {
    private init() {}

    /// Decide what a scanned code should do.
    /// - Parameters:
    ///   - decodeResult: The pure result of `CmxAttachTicketInput.decode`.
    ///   - isConnected: Whether a live session is currently up.
    ///   - activeMacDeviceID: The Mac the live session targets, when connected.
    /// - Returns: The disposition; always ``MobilePairingScanDisposition/proceed``
    ///   when not connected, so the disconnected pairing flow is unchanged.
    public static func disposition(
        decodeResult: Result<CmxAttachTicket, any Error>,
        isConnected: Bool,
        activeMacDeviceID: String?
    ) -> MobilePairingScanDisposition {
        guard isConnected, let activeMacDeviceID, !activeMacDeviceID.isEmpty else {
            return .proceed
        }
        switch decodeResult {
        case let .success(ticket):
            guard ticket.macDeviceID == activeMacDeviceID else { return .proceed }
            return .alreadyConnected(macName: ticket.macDisplayName)
        case let .failure(error):
            return .rejectKeepingConnection(MobilePairingFailureCategory.classify(decodeError: error))
        }
    }
}
