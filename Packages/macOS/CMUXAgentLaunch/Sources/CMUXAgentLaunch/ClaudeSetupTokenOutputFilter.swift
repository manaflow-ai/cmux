import Foundation

/// Passes `claude setup-token` output through as it arrives, with the minted
/// token replaced by `[REDACTED]`.
///
/// The sign-in link and the prompts have to reach the terminal while the
/// command is still running, so the output cannot be collected and cleaned
/// afterwards. Bytes that cannot be part of a token are returned by the call
/// that received them. A token is held back until the byte after it shows
/// where it ends, and is never returned.
public struct ClaudeSetupTokenOutputFilter: Sendable {
    /// The first token in the output so far.
    public private(set) var token: String?

    private static let marker = Array("sk-ant-oat01-".utf8)
    private static let replacement = Array("[REDACTED]".utf8)
    private static let minimumBodyLength = 20
    private static let maximumBodyLength = 1_000

    private enum State {
        /// Outside a token. `matched` marker bytes at the end are held back.
        case text(matched: Int)
        /// After the marker, collecting what may be a token.
        case body([UInt8])
        /// Inside a token longer than any real one; the rest is dropped.
        case overflow
    }

    private var state = State.text(matched: 0)

    public init() {}

    /// Returns the bytes of `bytes`, and of earlier calls, that are safe to
    /// print now.
    public mutating func consume(_ bytes: Data) -> Data {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        for byte in bytes {
            consume(byte, into: &output)
        }
        return Data(output)
    }

    /// Returns what was still held back when the output ended.
    public mutating func finish() -> Data {
        var output: [UInt8] = []
        switch state {
        case .text(let matched):
            output.append(contentsOf: Self.marker[..<matched])
        case .body(let body):
            settle(body, into: &output)
        case .overflow:
            break
        }
        state = .text(matched: 0)
        return Data(output)
    }

    private mutating func consume(_ byte: UInt8, into output: inout [UInt8]) {
        switch state {
        case .text(let matched):
            if byte == Self.marker[matched] {
                state = matched + 1 == Self.marker.count ? .body([]) : .text(matched: matched + 1)
                return
            }
            output.append(contentsOf: Self.marker[..<matched])
            // The marker's first byte appears nowhere else in it, so a failed
            // match can only restart at this byte.
            if byte == Self.marker[0] {
                state = .text(matched: 1)
            } else {
                state = .text(matched: 0)
                output.append(byte)
            }
        case .body(var body):
            guard Self.isTokenByte(byte) else {
                settle(body, into: &output)
                state = .text(matched: 0)
                consume(byte, into: &output)
                return
            }
            // Release the stored copy first so the append does not copy it.
            state = .overflow
            body.append(byte)
            if body.count == Self.maximumBodyLength {
                settle(body, into: &output)
            } else {
                state = .body(body)
            }
        case .overflow:
            guard !Self.isTokenByte(byte) else { return }
            state = .text(matched: 0)
            consume(byte, into: &output)
        }
    }

    /// A marker followed by too few token bytes is ordinary text, such as the
    /// prefix quoted in a help message.
    private mutating func settle(_ body: [UInt8], into output: inout [UInt8]) {
        guard body.count >= Self.minimumBodyLength else {
            output.append(contentsOf: Self.marker)
            output.append(contentsOf: body)
            return
        }
        if token == nil {
            token = String(decoding: Self.marker + body, as: UTF8.self)
        }
        output.append(contentsOf: Self.replacement)
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "_"), UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }
}
