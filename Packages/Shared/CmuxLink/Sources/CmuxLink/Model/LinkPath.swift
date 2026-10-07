/// The path a live transport uses.
public struct LinkPath: Sendable, Hashable {
    public var kind: PathKind
    public var carrier: CarrierKind

    public init(kind: PathKind, carrier: CarrierKind) {
        self.kind = kind
        self.carrier = carrier
    }
}
