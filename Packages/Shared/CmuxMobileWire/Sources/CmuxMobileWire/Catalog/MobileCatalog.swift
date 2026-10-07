/// The cmux.mobile/1 catalog (schemas/mobile-rpc/catalog.json). `v1`
/// is the built-in table; the tests assert it equals the JSON file.
public struct MobileCatalog: Hashable, Sendable, Codable {
    public var proto: String
    public var version: Int
    public var families: [MobileFamily]

    public init(proto: String, version: Int, families: [MobileFamily]) {
        self.proto = proto
        self.version = version
        self.families = families
    }

    /// The message with this name, if any.
    public func message(named name: String) -> MobileMessage? {
        for family in families {
            if let m = family.messages.first(where: { $0.name == name }) { return m }
        }
        return nil
    }

    /// The family that owns the message with this name, if any.
    public func family(ofMessage name: String) -> MobileFamily? {
        families.first { $0.messages.contains { $0.name == name } }
    }
}
