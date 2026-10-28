#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import CmuxNextWakeupsTestSupport
import Darwin
import Testing

/// Input to the Chromium host goes out at once and waits only under socket
/// back-pressure: a pointer flood to a host that has stopped
/// reading keeps the connection, holds at most one move, one wheel and one
/// geometry between two discrete frames, keeps the order of every discrete
/// frame, bounds the waiting bytes, and ends a host whose socket takes
/// nothing for a stall window.
@Suite struct ChromiumHostInputCoalescingTests {
    // MARK: Frames

    private static func move(_ x: Int32, buttons: Int32 = 0) -> ChromiumHostFrame {
        ChromiumHostFrame(.mouse, v: [x, 0, 0, 0, 0, buttons], t0: UInt64(x) * 1_000_000)
    }

    private static func key(_ seq: UInt32) -> ChromiumHostFrame {
        var frame = ChromiumHostFrame(.key, v: [0, 4, 0])
        frame.seq = seq
        return frame
    }

    private static func wheel(dy: Int32, flags: UInt64 = 0) -> ChromiumHostFrame {
        ChromiumHostFrame(.wheel, v: [10, 20, 0, dy], flags: flags)
    }

    private static func click() -> ChromiumHostFrame {
        ChromiumHostFrame(.mouse, v: [5, 5, 1, 0, 1, 1])
    }

    private static func geometry(_ width: Int32) -> ChromiumHostFrame {
        ChromiumHostFrame(.geometry, v: [0, 0, width, 100])
    }

    /// A key that carries `bytes` of text.
    private static func textKey(_ seq: UInt32, bytes: Int) -> ChromiumHostFrame {
        var frame = key(seq)
        frame.payload = [UInt8](repeating: 0x61, count: bytes)
        return frame
    }

    /// Decodes every whole frame of `bytes`.
    private static func decodeAll(_ bytes: [UInt8]) -> [ChromiumHostFrame] {
        var frames: [ChromiumHostFrame] = []
        var start = 0
        while case .frame(let frame, let consumed) = ChromiumHostFrame.decode(bytes[start...]) {
            frames.append(frame)
            start += consumed
        }
        return frames
    }

    /// Flushes `outbox` into a byte array that takes everything.
    private static func drain(_ outbox: inout ChromiumHostInputOutbox) -> [ChromiumHostFrame] {
        var bytes: [UInt8] = []
        let result = outbox.flush { chunk in
            bytes.append(contentsOf: chunk)
            return .wrote(chunk.count)
        }
        #expect(result == .drained)
        return decodeAll(bytes)
    }

    // MARK: The outbox

    @Test func movesFoldIntoTheWaitingMoveAtTheTail() {
        var outbox = ChromiumHostInputOutbox()
        for x in 0..<1_000 {
            let took = outbox.push(Self.move(Int32(x)))
            #expect(took)
        }
        #expect(outbox.waitingCount == 1)
        #expect(outbox.coalescibleCount == 1)
        #expect(outbox.coalesced == 999)
        #expect(Self.drain(&outbox) == [Self.move(999)])
        #expect(!outbox.hasUnwritten)
    }

    @Test func aDiscreteFrameKeepsTheMovesOnEitherSideOfIt() {
        var outbox = ChromiumHostInputOutbox()
        for frame in [Self.move(1), Self.move(2), Self.click(), Self.move(3), Self.move(4), Self.key(7)] {
            let took1 = outbox.push(frame)
            #expect(took1)
        }
        #expect(Self.drain(&outbox) == [Self.move(2), Self.click(), Self.move(4), Self.key(7)])
    }

    @Test func aMoveWithOtherButtonsDoesNotFold() {
        var outbox = ChromiumHostInputOutbox()
        let took2 = outbox.push(Self.move(1))
        #expect(took2)
        let took3 = outbox.push(Self.move(2, buttons: 1))
        #expect(took3)
        #expect(Self.drain(&outbox) == [Self.move(1), Self.move(2, buttons: 1)])
    }

    @Test func wheelDeltasAddUpPerModifiersAndSaturate() {
        var outbox = ChromiumHostInputOutbox()
        for _ in 0..<3 {
            let took = outbox.push(Self.wheel(dy: -4))
            #expect(took)
        }
        let took5 = outbox.push(Self.wheel(dy: 1, flags: 1 << 20))
        #expect(took5)
        let took6 = outbox.push(Self.wheel(dy: .max, flags: 1 << 20))
        #expect(took6)
        let frames = Self.drain(&outbox)
        #expect(frames.map { $0.v[3] } == [-12, .max])
        #expect(frames.map(\.flags) == [0, 1 << 20])
    }

    @Test func aPartlyWrittenFrameFinishesFirstAndTakesNoFold() {
        var outbox = ChromiumHostInputOutbox()
        let took7 = outbox.push(Self.move(1))
        #expect(took7)
        var bytes: [UInt8] = []
        // The socket takes 10 bytes, then is full.
        var room = 10
        let blocked = outbox.flush { chunk in
            guard room > 0 else { return .wouldBlock }
            let taken = min(room, chunk.count)
            room -= taken
            bytes.append(contentsOf: chunk.prefix(taken))
            return .wrote(taken)
        }
        #expect(blocked == .blocked)
        #expect(outbox.hasUnwritten)
        // The partly written move is in flight: a newer move queues after it.
        let took8 = outbox.push(Self.move(2))
        #expect(took8)
        let took9 = outbox.push(Self.key(1))
        #expect(took9)
        let drained = outbox.flush { chunk in
            bytes.append(contentsOf: chunk)
            return .wrote(chunk.count)
        }
        #expect(drained == .drained)
        #expect(Self.decodeAll(bytes) == [Self.move(1), Self.move(2), Self.key(1)])
    }

    @Test func theDiscreteQueueIsBoundedAndMovesStillFold() {
        var outbox = ChromiumHostInputOutbox()
        for seq in 0..<UInt32(ChromiumHostInputOutbox.discreteLimit) {
            let took = outbox.push(Self.key(seq))
            #expect(took)
        }
        let took11 = outbox.push(Self.key(UInt32.max))
        #expect(!took11)
        let took12 = outbox.push(Self.move(1))
        #expect(took12)
        let took13 = outbox.push(Self.move(2))
        #expect(took13)
        #expect(outbox.waitingCount == ChromiumHostInputOutbox.discreteLimit + 1)
        let frames = Self.drain(&outbox)
        #expect(frames.prefix(ChromiumHostInputOutbox.discreteLimit).map(\.seq) == Array(0..<UInt32(ChromiumHostInputOutbox.discreteLimit)))
        #expect(frames.last == Self.move(2))
    }

    @Test func interleavedMovesWheelsAndGeometryEachKeepOneSlot() {
        var outbox = ChromiumHostInputOutbox()
        for x in 0..<1_000 {
            let took14 = outbox.push(Self.move(Int32(x)))
            #expect(took14)
            let took15 = outbox.push(Self.wheel(dy: 1))
            #expect(took15)
            let took16 = outbox.push(Self.geometry(Int32(x)))
            #expect(took16)
        }
        #expect(outbox.waitingCount == 3)
        #expect(outbox.coalescibleCount == 3)
        #expect(Self.drain(&outbox) == [Self.move(999), Self.wheel(dy: 1_000), Self.geometry(999)])
    }

    @Test func aDiscreteFrameStartsNewSlots() {
        var outbox = ChromiumHostInputOutbox()
        for frame in [Self.move(1), Self.wheel(dy: 1), Self.move(2), Self.key(1), Self.wheel(dy: 2), Self.move(3), Self.wheel(dy: 3)] {
            let took17 = outbox.push(frame)
            #expect(took17)
        }
        #expect(Self.drain(&outbox) == [Self.move(2), Self.wheel(dy: 1), Self.key(1), Self.wheel(dy: 5), Self.move(3)])
    }

    @Test func theWaitingBytesAreBounded() {
        var outbox = ChromiumHostInputOutbox()
        let size = ChromiumHostFrame.headerSize + ChromiumHostFrame.maxPayload
        var pushed: UInt32 = 0
        while outbox.push(Self.textKey(pushed, bytes: ChromiumHostFrame.maxPayload)) { pushed += 1 }
        #expect(Int(pushed) == ChromiumHostInputOutbox.byteLimit / size)
        #expect(outbox.waitingBytes <= ChromiumHostInputOutbox.byteLimit)
        // Folding adds no bytes: moves still fit.
        let took18 = outbox.push(Self.move(1))
        #expect(took18)
        let took19 = outbox.push(Self.move(2))
        #expect(took19)
        #expect(outbox.coalescibleCount == 1)
    }

    @Test func oneFlushIsOneWrite() {
        var outbox = ChromiumHostInputOutbox()
        for seq in 0..<UInt32(100) {
            let took = outbox.push(Self.key(seq))
            #expect(took)
        }
        var writes = 0
        let result = outbox.flush { chunk in
            writes += 1
            return .wrote(chunk.count / 2)
        }
        #expect(result == .blocked)
        #expect(writes == 1)
        #expect(outbox.waitingBytes == 50 * ChromiumHostFrame.headerSize)
    }

    @Test func aSlotStillFoldsAfterTheWrittenBytesAreDropped() {
        var outbox = ChromiumHostInputOutbox()
        let keys = (0..<UInt32(2_000)).map(Self.key)
        for frame in keys {
            let took = outbox.push(frame)
            #expect(took)
        }
        let took22 = outbox.push(Self.move(1))
        #expect(took22)
        // The socket takes 100,000 bytes, most of what waits: the written bytes are dropped.
        var bytes: [UInt8] = []
        let blocked = outbox.flush { chunk in
            bytes.append(contentsOf: chunk.prefix(100_000))
            return .wrote(100_000)
        }
        #expect(blocked == .blocked)
        let took23 = outbox.push(Self.move(2))
        #expect(took23)
        let took24 = outbox.push(Self.key(9_999))
        #expect(took24)
        #expect(outbox.coalesced == 1)
        let drained = outbox.flush { chunk in
            bytes.append(contentsOf: chunk)
            return .wrote(chunk.count)
        }
        #expect(drained == .drained)
        #expect(Self.decodeAll(bytes) == keys + [Self.move(2), Self.key(9_999)])
    }

    // MARK: The connection over a socket pair

    /// A connection whose host is the test: `hostRead` reads what cmux sends,
    /// `hostWrite` is the host's sending end (never written here).
    private struct Wire {
        let connection: ChromiumHostConnection
        let hostRead: Int32
        let hostWrite: Int32

        init(clock: any Clock<Duration> = ContinuousClock()) throws {
            var toHost: [Int32] = [-1, -1]
            var fromHost: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &toHost) == 0)
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fromHost) == 0)
            connection = ChromiumHostConnection(readFD: fromHost[1], writeFD: toHost[0], clock: clock)
            hostRead = toHost[1]
            hostWrite = fromHost[0]
        }

        func close() {
            connection.close()
            _ = Darwin.close(hostRead)
            _ = Darwin.close(hostWrite)
        }

        /// Reads frames until one is `last`; nil when 10 s pass first.
        func read(until last: ChromiumHostFrame) -> [ChromiumHostFrame]? {
            var bytes: [UInt8] = []
            var start = 0
            var frames: [ChromiumHostFrame] = []
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                var poller = pollfd(fd: hostRead, events: Int16(POLLIN), revents: 0)
                // Bound of a test wait: the writable source flushes as soon as this read makes room.
                guard poll(&poller, 1, 10_000) == 1 else { return nil }
                let count = chunk.withUnsafeMutableBytes { Darwin.read(hostRead, $0.baseAddress, $0.count) }
                guard count > 0 else { return nil }
                bytes.append(contentsOf: chunk[0..<count])
                while case .frame(let frame, let consumed) = ChromiumHostFrame.decode(bytes[start...]) {
                    frames.append(frame)
                    start += consumed
                    if frame == last { return frames }
                }
            }
        }
    }

    /// Sends moves until the socket is full; returns how many went.
    @discardableResult
    private static func fillSocket(_ wire: Wire) throws -> Int32 {
        var sent: Int32 = 0
        while sent < 100_000, !wire.connection.backlog.writableArmed {
            #expect(wire.connection.send(Self.move(sent)))
            sent += 1
        }
        try #require(wire.connection.backlog.writableArmed)
        return sent
    }

    @Test func aFrameIsInTheSocketWhenSendReturns() throws {
        let wire = try Wire()
        defer { wire.close() }
        #expect(wire.connection.send(Self.move(1)))
        // No display tick, no queue hop: the bytes are readable at once.
        var poller = pollfd(fd: wire.hostRead, events: Int16(POLLIN), revents: 0)
        #expect(poll(&poller, 1, 0) == 1)
        #expect(wire.connection.backlog.waiting == 0)
        #expect(!wire.connection.backlog.writableArmed)
    }

    @Test func aMoveFloodWithAStoppedReaderKeepsTheConnectionAndTheOrder() throws {
        let wire = try Wire()
        defer { wire.close() }
        // A 1000 Hz pointer (t0 one millisecond apart) while the host reads nothing: moves fill the
        // socket, then ten more seconds of them wait in the outbox.
        var flood = 0
        while flood < 100_000, !wire.connection.backlog.writableArmed {
            #expect(wire.connection.send(Self.move(Int32(flood))))
            flood += 1
        }
        try #require(wire.connection.backlog.writableArmed)
        for x in flood..<(flood + 10_000) {
            #expect(wire.connection.send(Self.move(Int32(x))))
            #expect(wire.connection.backlog.coalescible <= 1)
        }
        flood += 10_000
        #expect(!wire.connection.endedByProtocolError)
        #expect(wire.connection.backlog.writableArmed)
        // Keys and moves interleaved while the socket stays full: none folds across a key.
        for seq in 0..<100 {
            #expect(wire.connection.send(Self.key(UInt32(seq))))
            #expect(wire.connection.send(Self.move(Int32(flood + seq))))
        }
        var ping = ChromiumHostFrame(.ping)
        ping.seq = 0xC0FFEE
        #expect(wire.connection.send(ping))
        #expect(!wire.connection.endedByProtocolError)

        // The host reads again: the writable source sends what waits, in order.
        let frames = try #require(wire.read(until: ping))
        let firstKey = try #require(frames.firstIndex { $0.kind == .key })
        #expect(frames[firstKey - 1] == Self.move(Int32(flood - 1)))  // the latest move before the first key
        let tail = Array(frames[firstKey...].dropLast())
        var expected: [ChromiumHostFrame] = []
        for seq in 0..<100 {
            expected.append(Self.key(UInt32(seq)))
            expected.append(Self.move(Int32(flood + seq)))
        }
        #expect(tail == expected)
        // Moves only ever went forward: nothing reordered within the flood.
        let moves = frames[..<firstKey].map { $0.v[0] }
        #expect(moves == moves.sorted())
        let backlog = wire.connection.backlog
        #expect(backlog.waiting == 0)
        #expect(backlog.coalescible == 0)
        #expect(backlog.coalesced > 0)
    }

    @Test func interleavedMovesAndWheelsWithAStoppedReaderKeepTheConnection() throws {
        let wire = try Wire()
        defer { wire.close() }
        let filled = try Self.fillSocket(wire)
        for x in filled..<(filled + 10_000) {
            #expect(wire.connection.send(Self.move(x)))
            #expect(wire.connection.send(Self.wheel(dy: 1)))
            #expect(wire.connection.backlog.coalescible <= 3)
        }
        #expect(!wire.connection.endedByProtocolError)
        var ping = ChromiumHostFrame(.ping)
        ping.seq = 0xC0FFEE
        #expect(wire.connection.send(ping))

        let frames = try #require(wire.read(until: ping))
        #expect(Array(frames.suffix(3)) == [Self.move(filled + 9_999), Self.wheel(dy: 10_000), ping])
        #expect(frames.filter { $0.kind == .wheel }.count == 1)
        #expect(!wire.connection.endedByProtocolError)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFullSocketThatTakesNothingForAStallWindowEndsTheConnection() async throws {
        let clock = ManualClock()
        let wire = try Wire(clock: clock)
        defer { wire.close() }
        try Self.fillSocket(wire)
        try await clock.waitForSleeper()
        #expect(!wire.connection.endedByProtocolError)
        clock.advance(by: ChromiumHostWireState.stallLimit)
        await wire.connection.readerEnded()
        #expect(wire.connection.endedByProtocolError)
        #expect(!wire.connection.send(Self.move(1)))
    }

    @Test(.timeLimit(.minutes(1)))
    func aHostThatTakesBytesWithinTheWindowKeepsTheConnection() async throws {
        let clock = ManualClock()
        let wire = try Wire(clock: clock)
        defer { wire.close() }
        try Self.fillSocket(wire)
        try await clock.waitForSleeper()
        // The marker waits in the outbox, with more text after it than the socket holds.
        let marker = Self.key(0xBEEF)
        #expect(wire.connection.send(marker))
        for seq in 0..<UInt32(900) { #expect(wire.connection.send(Self.textKey(seq, bytes: 1_024))) }
        // The host reads until the marker: the writable source wrote it, so the socket took bytes.
        _ = try #require(wire.read(until: marker))
        clock.advance(by: ChromiumHostWireState.stallLimit)
        // The check saw progress and starts the next window.
        try await clock.waitForSleeper()
        #expect(!wire.connection.endedByProtocolError)
        #expect(wire.connection.backlog.writableArmed)
    }
}
#endif
