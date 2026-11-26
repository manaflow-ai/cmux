/// Failures while applying a pairing-route disclosure policy.
public enum CmxAttachTicketCompactCoderError: Error, Equatable, Sendable {
    /// The selected disclosure mode removed every route from the payload.
    case noRoutesForDisclosureMode(CmxPairingRouteDisclosureMode)
}
