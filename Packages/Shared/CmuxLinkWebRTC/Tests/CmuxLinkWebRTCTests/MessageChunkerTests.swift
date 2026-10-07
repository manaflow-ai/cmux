@testable import CmuxLinkWebRTC
import Foundation
import Testing

@Suite("Message chunking")
struct MessageChunkerTests {
    let chunker = MessageChunker(maxMessageBytes: 8 * 1024)

    static func frame(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    }

    @Test("reliable frames split into in-order pieces of at most 8 KiB")
    func reliable() {
        for size in [0, 1, 8191, 8192, 256 * 1024] {
            let frame = Self.frame(size)
            let messages = chunker.split(frame, reliable: true, id: 0)
            #expect(messages.allSatisfy { $0.count <= 8 * 1024 })
            #expect(messages.dropLast().allSatisfy { $0.first == MessageChunker.more })
            #expect(messages.last?.first == MessageChunker.last)
            var reassembly = MessageReassembly(maxFrameBytes: 256 * 1024)
            let out = messages.compactMap { reassembly.receive($0) }
            #expect(out == [frame], "size \(size)")
        }
    }

    @Test("unordered pieces reassemble in any order; an incomplete frame is never delivered")
    func indexed() {
        let frame = Self.frame(40 * 1024)
        let messages = chunker.split(frame, reliable: false, id: 7)
        #expect(messages.count == 6)
        var reassembly = MessageReassembly(maxFrameBytes: 256 * 1024)
        #expect(messages.reversed().compactMap { reassembly.receive($0) } == [frame])
        var lossy = MessageReassembly(maxFrameBytes: 256 * 1024)
        #expect(messages.dropFirst().compactMap { lossy.receive($0) }.isEmpty)
        // Old incomplete frames are evicted; later ones still complete.
        for id in 8..<20 { _ = lossy.receive(chunker.split(frame, reliable: false, id: UInt32(id))[0]) }
        #expect(chunker.split(Self.frame(100), reliable: false, id: 30).compactMap { lossy.receive($0) } == [Self.frame(100)])
    }

    @Test("oversized and malformed messages are dropped")
    func malformed() {
        var reassembly = MessageReassembly(maxFrameBytes: 10_000)
        let big = chunker.split(Self.frame(20_000), reliable: true, id: 0)
        #expect(big.compactMap { reassembly.receive($0) }.isEmpty)
        #expect(reassembly.receive(Data([0x09, 1, 2])) == nil)
        #expect(reassembly.receive(Data()) == nil)
        #expect(reassembly.receive(Data([0x00, 5])) == Data([5]))
    }
}
