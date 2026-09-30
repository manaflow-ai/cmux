import Foundation

/// SSH hosts the user entered, kept in the home daemon's personal state
/// until their first successful connect (not implemented yet).
public struct SavedHostsDocument: Codable, Sendable, Hashable {
    public struct Host: Codable, Sendable, Hashable {
        public var id: String
        public var transport: [String: String]
        public var addedMs: UInt64
    }

    public static let limit = 64
    public var hosts: [Host] = []

    public init() {}

    public mutating func upsert(id: String, transport: [String: String], nowMs: UInt64) {}
    public mutating func remove(id: String) {}
    public func pending(registered: Set<String>) -> [Host] { [] }
    public mutating func pruned(registered: Set<String>) -> Bool { false }

    func jsonValue() throws -> JSONValue { .null }
    init(jsonValue: JSONValue) throws {}
}
