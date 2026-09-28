public import Foundation

/// Finds `OSC 21337 ; key=value ; ... ST` session status sequences in a raw
/// PTY output stream, across read boundaries.
///
/// Built for Ghostty's synchronous PTY tee: outside a sequence it only looks
/// for ESC, so ordinary output costs one byte search per read. Libghostty
/// discards this OSC number itself, so this scanner is the only consumer.
/// Payloads over `maximumPayloadBytes` are dropped whole, and the rest of an
/// oversized payload is skipped with a byte search for its terminator.
///
/// This is stricter than Ghostty's VT parser, on purpose: only BEL and
/// `ESC \` apply a sequence. Ghostty also dispatches an OSC that ends in ESC
/// followed by any other byte, CAN or SUB; here those cancel it. The 8-bit
/// C1 introducer (0x9D) is not recognized, and C0 controls inside the payload
/// are kept for the text sanitizer to strip rather than skipped.
public struct TerminalSessionStatusOSCScanner: Sendable {
    public static let maximumPayloadBytes = 1_024

    private enum State: Sendable {
        case ground
        case escape
        /// Matched this many bytes of `21337`.
        case identifier(Int)
        case payload
        case payloadEscape
    }

    private static let escape: UInt8 = 0x1B
    private static let bell: UInt8 = 0x07
    private static let cancel: UInt8 = 0x18
    private static let substitute: UInt8 = 0x1A
    private static let identifier: [UInt8] = Array("21337".utf8)

    private var state: State = .ground
    private var payload: [UInt8] = []
    private var payloadOverflowed = false

    public init() {}

    /// Consumes one PTY read and returns the complete updates it finished.
    public mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>) -> [TerminalSessionStatusUpdate] {
        guard let base = bytes.baseAddress else { return [] }
        var updates: [TerminalSessionStatusUpdate] = []
        var index = 0
        let count = bytes.count
        while index < count {
            if case .ground = state {
                guard let found = memchr(base + index, Int32(Self.escape), count - index) else {
                    return updates
                }
                index = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found)) + 1
                state = .escape
                continue
            }
            if case .payload = state, payloadOverflowed {
                // Nothing in an oversized payload is kept, so jump straight to
                // the next byte that can end it. CAN and SUB would also end
                // it, but a dropped payload ends the same way at the next
                // BEL or ESC.
                guard let terminator = Self.nextTerminatorIndex(in: bytes, from: index) else {
                    return updates
                }
                index = terminator
            }
            if let update = step(bytes[index]) {
                updates.append(update)
            }
            index += 1
        }
        return updates
    }

    public mutating func consume(_ data: Data) -> [TerminalSessionStatusUpdate] {
        data.withUnsafeBytes { raw in
            consume(raw.bindMemory(to: UInt8.self))
        }
    }

    private static func nextTerminatorIndex(in bytes: UnsafeBufferPointer<UInt8>, from index: Int) -> Int? {
        guard let base = bytes.baseAddress else { return nil }
        let start = base + index
        let origin = UnsafeRawPointer(base)
        let escapeIndex = memchr(start, Int32(escape), bytes.count - index)
            .map { origin.distance(to: UnsafeRawPointer($0)) }
        let searchEnd = escapeIndex ?? bytes.count
        let bellIndex = memchr(start, Int32(bell), searchEnd - index)
            .map { origin.distance(to: UnsafeRawPointer($0)) }
        return bellIndex ?? escapeIndex
    }

    private mutating func step(_ byte: UInt8) -> TerminalSessionStatusUpdate? {
        switch state {
        case .ground:
            if byte == Self.escape { state = .escape }
        case .escape:
            if byte == UInt8(ascii: "]") {
                state = .identifier(0)
            } else if byte != Self.escape {
                state = .ground
            }
        case .identifier(let matched):
            if matched == Self.identifier.count {
                if byte == UInt8(ascii: ";") {
                    beginPayload()
                } else {
                    // `OSC 21337 ST` or a longer number: nothing to apply.
                    state = byte == Self.escape ? .escape : .ground
                }
            } else if byte == Self.identifier[matched] {
                state = .identifier(matched + 1)
            } else {
                state = byte == Self.escape ? .escape : .ground
            }
        case .payload:
            switch byte {
            case Self.bell:
                return finishPayload()
            case Self.escape:
                state = .payloadEscape
            case Self.cancel, Self.substitute:
                abandonPayload(nextState: .ground)
            default:
                append(byte)
            }
        case .payloadEscape:
            if byte == UInt8(ascii: "\\") {
                return finishPayload()
            }
            abandonPayload(nextState: .escape)
            return step(byte)
        }
        return nil
    }

    private mutating func beginPayload() {
        state = .payload
        payload.removeAll(keepingCapacity: true)
        payloadOverflowed = false
    }

    private mutating func append(_ byte: UInt8) {
        guard !payloadOverflowed else { return }
        guard payload.count < Self.maximumPayloadBytes else {
            payloadOverflowed = true
            payload.removeAll()
            return
        }
        payload.append(byte)
    }

    private mutating func finishPayload() -> TerminalSessionStatusUpdate? {
        let update = payloadOverflowed ? nil : TerminalSessionStatusUpdate.parse(payload: payload)
        abandonPayload(nextState: .ground)
        return update
    }

    private mutating func abandonPayload(nextState: State) {
        state = nextState
        payload.removeAll(keepingCapacity: payload.count <= 256)
        payloadOverflowed = false
    }
}
