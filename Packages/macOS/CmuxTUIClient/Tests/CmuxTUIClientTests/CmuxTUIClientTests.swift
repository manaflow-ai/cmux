import Foundation
import Testing
@testable import CmuxTUIClient

struct CmuxTUIClientTests {
    @Test("Native render descriptor matches the Rust C ABI")
    func renderDescriptorLayout() {
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.size == 16)
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.stride == 16)
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.alignment == 8)
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.offset(of: \.kind) == 0)
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.offset(of: \.columns) == 4)
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.offset(of: \.rows) == 6)
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.offset(of: \.payloadLength) == 8)
    }

    @Test("Render event values remain wire compatible")
    func renderEventKinds() {
        #expect(CmuxTUIRenderEvent.Kind.reset.rawValue == 1)
        #expect(CmuxTUIRenderEvent.Kind.bytes.rawValue == 2)
        #expect(CmuxTUIRenderEvent.Kind.resize.rawValue == 3)
        #expect(CmuxTUIRenderEvent.Kind.ready.rawValue == 4)
        #expect(CmuxTUIRenderEvent.Kind.exit.rawValue == 5)
    }

    @Test("Growing C strings retry without truncating UTF-8")
    func growingCStringRetries() {
        var calls = 0
        let result = copyBoundedCString(
            maximumPayloadBytes: 32,
            maximumAttempts: 4
        ) { buffer, capacity in
            calls += 1
            guard let buffer else { return 2 }
            guard capacity >= 5 else { return 4 }
            buffer[0] = 0x74
            buffer[1] = 0x65
            buffer[2] = 0x73
            buffer[3] = 0x74
            buffer[4] = 0
            return 4
        }

        #expect(result == "test")
        #expect(calls == 3)
    }

    @Test("Growing C strings reject negative and oversized lengths")
    func growingCStringRejectsInvalidLengths() {
        #expect(copyBoundedCString(maximumPayloadBytes: 32) { _, _ in -1 } == nil)

        var secondPass = false
        #expect(copyBoundedCString(maximumPayloadBytes: 32) { _, _ in
            if secondPass { return -1 }
            secondPass = true
            return 4
        } == nil)

        #expect(copyBoundedCString(maximumPayloadBytes: 32) { _, _ in 33 } == nil)
    }

    @Test("Growing C strings stop when the producer never stabilizes")
    func growingCStringAttemptsAreBounded() {
        var calls = 0
        let result = copyBoundedCString(
            maximumPayloadBytes: 32,
            maximumAttempts: 4
        ) { buffer, capacity in
            calls += 1
            return buffer == nil ? 1 : capacity
        }

        #expect(result == nil)
        #expect(calls == 5)
    }

    @Test("Render drains yield after a bounded number of empty events")
    func renderDrainBoundsEventCount() throws {
        var copies = 0
        let batch = try drainCmuxTUIRenderEventBatch { descriptor, _, _ in
            copies += 1
            descriptor.kind = CmuxTUIRenderEvent.Kind.ready.rawValue
            descriptor.columns = 80
            descriptor.rows = 24
            descriptor.payloadLength = 0
            return true
        }

        #expect(batch.events.count == 256)
        #expect(batch.hasMore)
        #expect(copies == 256)
    }

    @Test("Render drains defer the next payload at the batch byte boundary")
    func renderDrainBoundsPayloadBytes() throws {
        let source = RenderEventSource([
            .init(kind: CmuxTUIRenderEvent.Kind.bytes.rawValue, payload: Data(repeating: 1, count: 5)),
            .init(kind: CmuxTUIRenderEvent.Kind.bytes.rawValue, payload: Data(repeating: 2, count: 5)),
        ])

        let first = try drainCmuxTUIRenderEventBatch(
            maximumEventCount: 256,
            maximumBatchPayloadBytes: 8,
            maximumEventPayloadBytes: 32,
            copyNext: source.copyNext
        )
        #expect(first.events.map(\.payload.count) == [5])
        #expect(first.hasMore)

        let second = try drainCmuxTUIRenderEventBatch(
            maximumEventCount: 256,
            maximumBatchPayloadBytes: 8,
            maximumEventPayloadBytes: 32,
            copyNext: source.copyNext
        )
        #expect(second.events.map(\.payload.count) == [5])
        #expect(!second.hasMore)
    }

    @Test("Unknown render events are consumed before reporting incompatibility")
    func unknownRenderEventDoesNotBlockTheQueue() {
        let source = RenderEventSource([
            .init(kind: 999, payload: Data([1, 2, 3])),
        ])

        #expect(throws: CmuxTUIClientError.self) {
            _ = try drainCmuxTUIRenderEventBatch(copyNext: source.copyNext)
        }
        #expect(source.remainingEventCount == 0)
    }
}

private final class RenderEventSource {
    struct Event {
        let kind: UInt32
        var columns: UInt16 = 80
        var rows: UInt16 = 24
        let payload: Data
    }

    private var events: [Event]

    init(_ events: [Event]) {
        self.events = events
    }

    var remainingEventCount: Int { events.count }

    func copyNext(
        descriptor: inout CmuxTUIRenderEventDescriptor,
        buffer: UnsafeMutablePointer<UInt8>?,
        capacity: Int
    ) -> Bool {
        guard let event = events.first else { return false }
        descriptor.kind = event.kind
        descriptor.columns = event.columns
        descriptor.rows = event.rows
        descriptor.payloadLength = event.payload.count

        if event.payload.isEmpty {
            events.removeFirst()
            return true
        }
        guard let buffer, capacity >= event.payload.count else { return true }
        _ = event.payload.copyBytes(
            to: UnsafeMutableBufferPointer(start: buffer, count: event.payload.count)
        )
        events.removeFirst()
        return true
    }
}
