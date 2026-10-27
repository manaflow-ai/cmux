public struct IrxAdmissionDenied: Error, Equatable, Sendable {
    public var code: IrxCloseCode

    public init(code: IrxCloseCode) {
        self.code = code
    }
}

/// Admission judgment seam: given the (optional) presented grant JWS and the
/// TLS-proved remote key, either return the admitted peer tuple or throw
/// ``IrxAdmissionDenied``. The list judge ignores the grant entirely; the
/// legacy grant judge requires one. Deliberately OFFLINE (no backend call
/// sits on the admission path - revocations enforce via the pushed device
/// list, or at the next admission).
public typealias IrxGrantJudgment =
    @Sendable (_ grantJWS: String?, _ remoteEndpointIDHex: String) throws -> IrxAdmittedPeerInfo
