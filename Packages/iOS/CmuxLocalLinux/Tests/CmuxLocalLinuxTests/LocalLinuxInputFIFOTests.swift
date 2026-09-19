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

    @Test("grows past the initial capacity without reordering elements")
    func growsPastInitialCapacity() {
        var fifo = LocalLinuxInputFIFO()
        let values = (0..<40).map { Data("chunk-\($0)".utf8) }
        for value in values {
            fifo.append(value)
        }

        for value in values {
            #expect(fifo.headRemainder == value)
            fifo.consume(value.count)
        }

        #expect(fifo.isEmpty)
        #expect(fifo.byteCount == 0)
    }

    @Test("preserves order while appending and consuming across ring boundaries")
    func wrapsWhileAppendingAndConsuming() {
        var fifo = LocalLinuxInputFIFO()
        var expected = [UInt8]()
        var expectedHead = 0

        for value in 0..<192 {
            let byte = UInt8(value % 251)
            fifo.append(Data([byte]))
            expected.append(byte)

            // Consume every other append. This keeps the queue live while the
            // logical head crosses the backing ring boundary many times.
            if value.isMultiple(of: 2) {
                #expect(fifo.headRemainder == Data([expected[expectedHead]]))
                fifo.consume(1)
                expectedHead += 1
            }
        }

        while expectedHead < expected.count {
            #expect(fifo.headRemainder == Data([expected[expectedHead]]))
            fifo.consume(1)
            expectedHead += 1
        }

        #expect(fifo.isEmpty)
        #expect(fifo.byteCount == 0)
    }
}
