import CmuxMobileWire

/// Cursor shape: a CSS cursor name in `kind`, or `custom` with an image hash.
public struct RbCursorShape: Hashable, Sendable {
    public var kind: String
    public var hash: String?

    public init(kind: String, hash: String? = nil) {
        self.kind = kind
        self.hash = hash
    }

    var jsonValue: JSONValue { .object(["kind": .string(kind), "hash": hash.rbJSON]) }

    init(json: JSONValue) throws(RdWireError) {
        let r = try RbJSONReader(json)
        kind = try r.string("kind")
        hash = r.optionalString("hash")
    }
}
