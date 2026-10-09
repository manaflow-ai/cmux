/// An owner event the mirror could not apply; the mirror asks for a snapshot.
public struct TrustStoreEventError: Error, Hashable, Sendable {
    public var field: String

    public init(field: String) { self.field = field }
}
