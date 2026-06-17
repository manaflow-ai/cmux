import Foundation

/// A destination for client-to-server bytes. Backed by `NWConnection` at
/// runtime, by an array in tests.
public protocol RFBByteSink: Sendable {
    func write(_ bytes: [UInt8]) async throws
}

/// An in-memory ``RFBByteSink`` that records everything written, for tests.
public actor InMemoryByteSink: RFBByteSink {
    public private(set) var written: [UInt8] = []

    public init() {}

    public func write(_ bytes: [UInt8]) async throws {
        written.append(contentsOf: bytes)
    }

    public func contents() -> [UInt8] { written }
}
