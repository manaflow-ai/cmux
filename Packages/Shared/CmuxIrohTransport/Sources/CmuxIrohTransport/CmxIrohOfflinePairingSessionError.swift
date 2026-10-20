/// Local invitation lifecycle failures. Grant-verification failures remain distinct.
public enum CmxIrohOfflinePairingSessionError: Error, Equatable, Sendable {
    case pairingDisabled
    case revoked
    case invalidInvitation
    case sessionUnavailable
    case invalidProof
    case randomnessUnavailable
}
