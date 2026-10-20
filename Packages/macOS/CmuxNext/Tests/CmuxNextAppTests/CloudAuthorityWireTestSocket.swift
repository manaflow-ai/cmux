import Foundation
@testable import CmuxNextCloud

actor CloudAuthorityWireTestSocket: CloudAuthorityWireSocket {
    private let input = AsyncThrowingStream<Data, any Error>.makeStream()
    private let sent = AsyncStream<Data>.makeStream()
    private var closed = false
    private(set) var closes = 0

    func receive() async throws -> Data {
        var iterator = input.stream.makeAsyncIterator()
        guard let data = try await iterator.next() else { throw CloudAuthorityWireLease.Failure.closed }
        return data
    }
    func send(_ data: Data) { sent.continuation.yield(data) }
    func close() {
        guard !closed else { return }
        closed = true; closes += 1
        input.continuation.finish(); sent.continuation.finish()
    }
    func emit(_ text: String) { input.continuation.yield(Data(text.utf8)) }
    func emit(_ data: Data) { input.continuation.yield(data) }
    func eof() { input.continuation.finish(throwing: CloudAuthorityWireLease.Failure.closed) }
    func nextSent() async -> Data? { var iterator = sent.stream.makeAsyncIterator(); return await iterator.next() }
}
