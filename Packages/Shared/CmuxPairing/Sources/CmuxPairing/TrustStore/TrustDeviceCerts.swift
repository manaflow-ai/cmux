/// The long-lived link certs a device published (one per purpose).
public struct TrustDeviceCerts: Hashable, Sendable, Codable {
    public var direct: LinkCertificate?
    public var wg: LinkCertificate?

    public init(direct: LinkCertificate? = nil, wg: LinkCertificate? = nil) {
        self.direct = direct
        self.wg = wg
    }

    public subscript(purpose: LinkPurpose) -> LinkCertificate? {
        get {
            switch purpose {
            case .direct: direct
            case .wg: wg
            case .dtls: nil
            }
        }
        set {
            switch purpose {
            case .direct: direct = newValue
            case .wg: wg = newValue
            case .dtls: break
            }
        }
    }
}
