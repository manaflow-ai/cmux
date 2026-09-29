import Foundation
@testable import CmuxNextMobile

/// In-memory `MobileByteLane` pair for splice tests: what one end writes the
/// other end reads.
actor MemoryPipe {
    private var chunks: [Data] = []
    private var closed = false
    private var waiters: [CheckedContinuation<Data?, Never>] = []

    func push(_ data: Data) {
        guard !closed else { return }
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: data) } else { chunks.append(data) }
    }

    func pop() async -> Data? {
        if !chunks.isEmpty { return chunks.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func close() {
        closed = true
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
    }
}

struct MemoryLane: MobileByteLane {
    let inbound: MemoryPipe
    let outbound: MemoryPipe

    static func pair() -> (MemoryLane, MemoryLane) {
        let a = MemoryPipe(), b = MemoryPipe()
        return (MemoryLane(inbound: a, outbound: b), MemoryLane(inbound: b, outbound: a))
    }

    func read(maximumBytes: Int) async throws -> Data? { await inbound.pop() }
    func write(_ data: Data) async throws { await outbound.push(data) }
    func close() async {
        await inbound.close()
        await outbound.close()
    }

    /// Reads until `count` newline-terminated lines arrived.
    func readLines(_ count: Int) async -> [String] {
        var text = ""
        while text.filter({ $0 == "\n" }).count < count, let chunk = await inbound.pop() {
            text += String(decoding: chunk, as: UTF8.self)
        }
        return text.split(separator: "\n").map(String.init)
    }
}
