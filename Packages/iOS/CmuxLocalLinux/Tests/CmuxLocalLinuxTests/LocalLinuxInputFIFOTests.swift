import Foundation
import Testing

@testable import CmuxLocalLinux

@Suite("Local Linux input FIFO")
struct LocalLinuxInputFIFOTests {
    @Test("preserves order across partial writes and wraparound")
    func preservesOrderAcrossPartialWrites() {
        var fifo = LocalLinuxInputFIFO()
        fifo.append(Data("abc".utf8))
        fifo.append(Data("def".utf8))

        #expect(fifo.byteCount == 6)
        #expect(String(decoding: fifo.headRemainder, as: UTF8.self) == "abc")

        fifo.consume(2)
        #expect(fifo.byteCount == 4)
        #expect(String(decoding: fifo.headRemainder, as: UTF8.self) == "c")

        fifo.consume(1)
        #expect(String(decoding: fifo.headRemainder, as: UTF8.self) == "def")

        fifo.consume(2)
        fifo.append(Data("ghi".utf8))
        #expect(String(decoding: fifo.headRemainder, as: UTF8.self) == "f")
        fifo.consume(1)
        #expect(String(decoding: fifo.headRemainder, as: UTF8.self) == "ghi")
    }

    @Test("clears queued bytes and releases the logical head")
    func clearsQueue() {
        var fifo = LocalLinuxInputFIFO()
        for value in 0..<32 {
            fifo.append(Data([UInt8(value)]))
        }

        fifo.removeAll(keepingCapacity: true)

        #expect(fifo.isEmpty)
        #expect(fifo.byteCount == 0)
        #expect(fifo.headByteCount == 0)
        #expect(fifo.headRemainder.isEmpty)
    }
}
