package import Foundation

/// A single bounded owner connection; its caller joins the reader before releasing it.
package protocol CloudAuthorityWireSocket: Sendable {
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func close() async
}
