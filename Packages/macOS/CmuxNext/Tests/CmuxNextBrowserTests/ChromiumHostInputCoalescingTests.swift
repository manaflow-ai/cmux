#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import Darwin
import Testing

/// Input to the Chromium host goes out at once and waits only under socket
/// back-pressure (p04-input-038): a pointer flood to a host that has stopped
/// reading keeps the connection, holds at most one move between two discrete
/// frames, and keeps the order of every discrete frame.
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
        for x in 0..<1_000 { #expect(outbox.push(Self.move(Int32(x)))) }
        #expect(outbox.waitingCount == 1)
        #expect(outbox.coalescibleCount == 1)
        #expect(outbox.coalesced == 999)
        #expect(Self.drain(&outbox) == [Self.move(999)])
        #expect(!outbox.hasUnwritten)
    }

    @Test func aDiscreteFrameKeepsTheMovesOnEitherSideOfIt() {
        var outbox = ChromiumHostInputOutbox()
        for frame in [Self.move(1), Self.move(2), Self.click(), Self.move(3), Self.move(4), Self.key(7)] {
            #expect(outbox.push(frame))
        }
        #expect(Self.drain(&outbox) == [Self.move(2), Self.click(), Self.move(4), Self.key(7)])
    }

    @Test func aMoveWithOtherButtonsDoesNotFold() {
        var outbox = ChromiumHostInputOutbox()
        #expect(outbox.push(Self.move(1)))
        #expect(outbox.push(Self.move(2, buttons: 1)))
        #expect(Self.drain(&outbox) == [Self.move(1), Self.move(2, buttons: 1)])
    }

    @Test func wheelDeltasAddUpPerModifiersAndSaturate() {
        var outbox = ChromiumHostInputOutbox()
        for _ in 0..<3 { #expect(outbox.push(Self.wheel(dy: -4))) }
        #expect(outbox.push(Self.wheel(dy: 1, flags: 1 << 20)))
        #expect(outbox.push(Self.wheel(dy: .max, flags: 1 << 20)))
        let frames = Self.drain(&outbox)
        #expect(frames.map { $0.v[3] } == [-12, .max])
        #expect(frames.map(\.flags) == [0, 1 << 20])
    }

    @Test func aPartlyWrittenFrameFinishesFirstAndTakesNoFold() {
        var outbox = ChromiumHostInputOutbox()
        #expect(outbox.push(Self.move(1)))
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
        #expect(outbox.push(Self.move(2)))
        #expect(outbox.push(Self.key(1)))
        let drained = outbox.flush { chunk in
            bytes.append(contentsOf: chunk)
            return .wrote(chunk.count)
        }
        #expect(drained == .drained)
        #expect(Self.decodeAll(bytes) == [Self.move(1), Self.move(2), Self.key(1)])
    }

    @Test func theDiscreteQueueIsBoundedAndMovesStillFold() {
        var outbox = ChromiumHostInputOutbox()
        for seq in 0..<UInt32(ChromiumHostInputOutbox.discreteLimit) { #expect(outbox.push(Self.key(seq))) }
        #expect(!outbox.push(Self.key(UInt32.max)))
        #expect(outbox.push(Self.move(1)))
        #expect(outbox.push(Self.move(2)))
        #expect(outbox.waitingCount == ChromiumHostInputOutbox.discreteLimit + 1)
        let frames = Self.drain(&outbox)
        #expect(frames.prefix(ChromiumHostInputOutbox.discreteLimit).map(\.seq) == Array(0..<UInt32(ChromiumHostInputOutbox.discreteLimit)))
        #expect(frames.last == Self.move(2))
    }

    @Test func laterWheelsWaitInOneSlotForTheFirstWheelsAck() {
        var outbox = ChromiumHostInputOutbox()
        #expect(outbox.push(Self.wheel(dy: 1)))
        outbox.holdWheelsUntilAck()
        #expect(outbox.push(Self.wheel(dy: 2)))
        #expect(outbox.push(Self.key(3)))
        #expect(outbox.push(Self.wheel(dy: 5)))
        #expect(outbox.coalescibleCount == 2)  // the first wheel waits for the socket, the held one for the ACK
        #expect(Self.drain(&outbox).map(\.kind) == [.wheel, .key])
        #expect(outbox.heldWheel?.v[3] == 7)
        #expect(outbox.wheelAcknowledged())
        #expect(outbox.heldWheel == nil)
        #expect(Self.drain(&outbox).map { $0.v[3] } == [7])
        // Acknowledged: wheels go at once again.
        #expect(outbox.push(Self.wheel(dy: 1)))
        #expect(outbox.heldWheel == nil)
        #expect(outbox.waitingCount == 1)
    }

    // MARK: The connection over a socket pair

    /// A connection whose host is the test: `hostRead` reads what cmux sends,
    /// `hostWrite` is the host's sending end (never written here).
    private struct Wire {
        let connection: ChromiumHostConnection
        let hostRead: Int32
        let hostWrite: Int32

        init() throws {
            var toHost: [Int32] = [-1, -1]
            var fromHost: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &toHost) == 0)
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fromHost) == 0)
            connection = ChromiumHostConnection(readFD: fromHost[1], writeFD: toHost[0])
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
        // Ten seconds of a 1000 Hz pointer (t0 one millisecond apart) while the host reads nothing.
        let flood = 10_000
        for x in 0..<flood {
            #expect(wire.connection.send(Self.move(Int32(x))))
            #expect(wire.connection.backlog.coalescible <= 1)
        }
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
}
#endif
