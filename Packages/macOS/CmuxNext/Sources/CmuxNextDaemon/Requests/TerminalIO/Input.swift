public import Foundation

/// Writes to a PTY. `bytes` travels as standard base64.
public struct SendInputRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "send"
    public var surface: SurfaceID
    public var text: String?
    public var bytes: Data?
    public var paste: Bool?
    /// `send-expect-foreground-v1`: the daemon writes only while the terminal's foreground
    /// executable is still this one (``TerminalProcessInfoRequest``'s `foregroundExecutable`), checked
    /// right before the write, and fails the request otherwise. A daemon without the capability
    /// ignores it, so a caller keeps its own check first.
    public var expectForeground: String?
    /// The key press this input carries (`CMUX_NEXT_TRACE_FLOWS`, `TypingLatencyProbe.openFlow(for:)`): the daemon
    /// only records it in its flow marks. Nil (left out of the line) otherwise; an older daemon ignores it.
    public var flow: UInt64?
    public init(surface: SurfaceID, text: String? = nil, bytes: Data? = nil, paste: Bool? = nil,
                expectForeground: String? = nil, flow: UInt64? = nil) {
        self.surface = surface
        self.text = text
        self.bytes = bytes
        self.paste = paste
        self.expectForeground = expectForeground
        self.flow = flow
    }
}

/// Writes to a terminal by its host id, also one still being created
/// (`terminal-input-while-creating-v1`): the daemon queues input for a creating terminal and
/// writes it after the commit, before any later input. Bytes it cannot write come back in one
/// ``TerminalInputUnclaimed`` event on this connection.
public struct SendTerminalInputRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// True when the terminal was still being created: the bytes wait in the daemon.
        public var queued: Bool?
    }
    public static let command = "send"
    public var terminalID: String
    public var bytes: Data
    public init(terminalID: String, bytes: Data) {
        self.terminalID = terminalID
        self.bytes = bytes
    }
}

/// Bytes the daemon queued for a terminal that was being created and did not write
/// (`terminal-input-while-creating-v1`), sent to the connection that queued them. The client
/// gives them to the terminal that has focus.
public struct TerminalInputUnclaimed: Decodable, Sendable, Equatable {
    /// The event name (one place, so the protocol name can change here only).
    public static let eventName = "terminal-input-unclaimed"
    public var terminalId: String
    public var bytesBase64: String
    /// `failed`, `cancelled`, `expired` or `write-failed`.
    public var reason: String
    public var bytes: Data? { Data(base64Encoded: bytesBase64) }
    /// The give-back in `event`, a side event of the control connection; nil for any other event.
    public init?(_ event: DaemonEvent) {
        guard case .unknown(let name, let payload) = event, name == Self.eventName,
              let terminalID = payload["terminal_id"]?.stringValue,
              let bytesBase64 = payload["bytes_base64"]?.stringValue else { return nil }
        self.terminalId = terminalID
        self.bytesBase64 = bytesBase64
        reason = payload["reason"]?.stringValue ?? ""
    }
    enum CodingKeys: String, CodingKey {
        case terminalId = "terminal_id", bytesBase64 = "bytes_base64", reason
    }
}

public struct SendKeyRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "send-key"
    public var surface: SurfaceID
    public var keys: [String]
    public init(surface: SurfaceID, keys: [String]) {
        self.surface = surface
        self.keys = keys
    }
}

public struct AttachSurfaceRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var lease: String?
        /// This view's sizing participant and the terminal's size state, for a connection that
        /// lists `shared-sizing-v1`.
        public var participant: String?
        public var sizeState: TerminalSizeState?
        enum CodingKeys: String, CodingKey {
            case lease, participant
            case sizeState = "size_state"
        }
    }
    public static let command = "attach-surface"
    public var surface: SurfaceID?
    public var expectedGeneration: DaemonGeneration?
    /// The public terminal id `term_…` (a tab's `terminal_resource_id`).
    public var expectedTerminalID: ResourceID?
    public var mode: String
    public var cols: Int?
    public var rows: Int?
    /// `ghostsnp` asks for snapshots (`terminal-snapshot-v1`) when the
    /// host's GHOSTSNP version equals `snapshotVersion`; any other version
    /// gets the byte replay.
    public var snapshot: String?
    public var snapshotVersion: UInt16?
    /// The view restores local-history READYs at a resize
    /// (`terminal-snapshot-local-history-v1`).
    public var snapshotLocalHistory: Bool?
    /// The view applies Kitty image replays (`terminal-snapshot-images-v1`).
    public var snapshotImages: Bool?

    /// - Parameter snapshotVersion: the viewer's GHOSTSNP version, or nil for
    ///   a byte replay.
    public init(surface: SurfaceID?, expectedGeneration: DaemonGeneration? = nil, expectedTerminalID: ResourceID? = nil,
                size: CellSize?, snapshotVersion: UInt16? = nil, snapshotLocalHistory: Bool = false,
                snapshotImages: Bool = false) {
        self.surface = surface
        self.expectedGeneration = expectedGeneration
        self.expectedTerminalID = expectedTerminalID
        self.mode = "bytes"
        self.cols = size?.cols
        self.rows = size?.rows
        self.snapshot = snapshotVersion == nil ? nil : "ghostsnp"
        self.snapshotVersion = snapshotVersion
        self.snapshotLocalHistory = snapshotVersion != nil && snapshotLocalHistory ? true : nil
        self.snapshotImages = snapshotVersion != nil && snapshotImages ? true : nil
    }
}

extension SendInputRequest {
    /// The `send` line of one key press's bytes (`{"bytes":…,"cmd":"send","flow":…,"id":…,"surface":…}`, no
    /// newline), byte for byte what ``WireCoding/encodeRequest(_:id:)`` writes for it (sorted keys, standard
    /// base64, no flow when nil). Every key typed into a daemon terminal comes here
    /// (`TerminalAttachment.enqueueInput`), so it is written into a stack buffer and copied once into a `Data` with
    /// room for the newline the transport appends: no `JSONEncoder`, no key-name conversion, no base64 String.
    static func keyLine(surface: SurfaceID, bytes: Data, flow: UInt64?, id: UInt64) -> Data { // perf-hot: 20us terminal-key (every key typed into a terminal)
        // The fixed text, the base64 digits and three numbers of at most 20 digits.
        let capacity = KeyLineText.fixedCount + (bytes.count + 2) / 3 * 4 + 3 * 20
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: capacity) { buffer -> Data in
            guard let start = buffer.baseAddress else { return Data() }
            var cursor = start
            KeyLineText.write(KeyLineText.bytesPrefix, at: &cursor)
            bytes.withUnsafeBytes { raw in KeyLineText.writeBase64(raw, at: &cursor) }
            KeyLineText.write(KeyLineText.cmdField, at: &cursor)
            if let flow {
                KeyLineText.write(KeyLineText.flowField, at: &cursor)
                KeyLineText.writeDecimal(flow, at: &cursor)
            }
            KeyLineText.write(KeyLineText.idField, at: &cursor)
            KeyLineText.writeDecimal(id, at: &cursor)
            KeyLineText.write(KeyLineText.surfaceField, at: &cursor)
            KeyLineText.writeDecimal(surface.rawValue, at: &cursor)
            KeyLineText.put(UInt8(ascii: "}"), at: &cursor)
            let count = cursor - start
            var line = Data(capacity: count + 1)
            line.append(start, count: count)
            return line
        }
    }
}

/// The text of a key's `send` line (``SendInputRequest/keyLine(surface:bytes:flow:id:)``), written through a
/// cursor into a buffer the caller sized: static strings, base64 digits and decimal numbers, no allocation.
private nonisolated struct KeyLineText {
    // Each of several characters: a one-character StaticString keeps a scalar, not a pointer (`utf8Start` traps).
    static let bytesPrefix: StaticString = #"{"bytes":""#
    static let cmdField: StaticString = #"","cmd":"send""#
    static let flowField: StaticString = #","flow":"#
    static let idField: StaticString = #","id":"#
    static let surfaceField: StaticString = #","surface":"#
    /// The fixed text and the closing brace.
    static let fixedCount = bytesPrefix.utf8CodeUnitCount + cmdField.utf8CodeUnitCount + flowField.utf8CodeUnitCount
        + idField.utf8CodeUnitCount + surfaceField.utf8CodeUnitCount + 1

    static func write(_ text: StaticString, at cursor: inout UnsafeMutablePointer<UInt8>) {
        cursor.initialize(from: text.utf8Start, count: text.utf8CodeUnitCount)
        cursor += text.utf8CodeUnitCount
    }

    static func put(_ byte: UInt8, at cursor: inout UnsafeMutablePointer<UInt8>) {
        cursor.initialize(to: byte)
        cursor += 1
    }

    /// Standard base64 with `=` padding, as `Data.base64EncodedString()` writes it: three bytes at a time into
    /// four digits, the last group padded.
    static func writeBase64(_ bytes: UnsafeRawBufferPointer, at cursor: inout UnsafeMutablePointer<UInt8>) {
        var group: UInt32 = 0
        var filled = 0
        for byte in bytes {
            group = group << 8 | UInt32(truncatingIfNeeded: byte)
            filled += 1
            guard filled == 3 else { continue }
            writeDigits(of: group, count: 4, at: &cursor)
            group = 0
            filled = 0
        }
        switch filled {
        case 1:
            writeDigits(of: group << 16, count: 2, at: &cursor)
            put(UInt8(ascii: "="), at: &cursor)
            put(UInt8(ascii: "="), at: &cursor)
        case 2:
            writeDigits(of: group << 8, count: 3, at: &cursor)
            put(UInt8(ascii: "="), at: &cursor)
        default:
            break
        }
    }

    /// The first `count` base64 digits of the 24-bit `group`, most significant first (bits 18, 12, 6, 0).
    static func writeDigits(of group: UInt32, count: Int, at cursor: inout UnsafeMutablePointer<UInt8>) {
        var shift: UInt32 = 18
        for _ in 0..<count {
            put(base64Digit(UInt8(truncatingIfNeeded: group >> shift & 63)), at: &cursor)
            shift &-= 6
        }
    }

    /// The base64 digit of a 6-bit value (`A`-`Z`, `a`-`z`, `0`-`9`, `+`, `/`).
    static func base64Digit(_ value: UInt8) -> UInt8 {
        switch value {
        case 0..<26: UInt8(ascii: "A") &+ value
        case 26..<52: UInt8(ascii: "a") &+ (value &- 26)
        case 52..<62: UInt8(ascii: "0") &+ (value &- 52)
        case 62: UInt8(ascii: "+")
        default: UInt8(ascii: "/")
        }
    }

    /// `value` in decimal, as the JSON encoder writes an unsigned integer: one digit per power of ten from the
    /// first nonzero one (at least one digit).
    static func writeDecimal(_ value: UInt64, at cursor: inout UnsafeMutablePointer<UInt8>) {
        var rest = value
        var power: UInt64 = 10_000_000_000_000_000_000  // the largest power of ten a UInt64 holds
        var started = false
        for _ in 0..<20 {
            let digit = rest / power
            rest -= digit &* power
            if started || digit > 0 || power == 1 {
                started = true
                put(UInt8(ascii: "0") &+ UInt8(truncatingIfNeeded: digit), at: &cursor)
            }
            power /= 10
        }
    }
}
