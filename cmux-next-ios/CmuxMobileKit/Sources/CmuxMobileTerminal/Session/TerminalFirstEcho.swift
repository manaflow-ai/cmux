import Foundation

/// The launch marks' first terminal key (`LaunchMarks`: `terminal_key_sent`,
/// `terminal_echo_presented`), bound to one input in one terminal: a single
/// printable key its session accepted, then the first output batch of that
/// terminal that holds the key's byte as text (outside escape sequences), then
/// the frame presented after Ghostty parsed that batch. The owner arms one
/// tracker per process (the marks are process-wide); after it every call
/// returns at once, so its cost stays constant however long the session runs.
public struct TerminalFirstEcho: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// No key typed yet.
        case idle
        /// The key went out; its echo is awaited.
        case sent(UInt8)
        /// A batch with the echo was handed to Ghostty; parsed when `parsed`.
        case fed(parsed: Bool)
        /// The echo's frame was presented.
        case done
    }

    /// Where the output is in an escape sequence, carried across batches.
    enum Escape: Sendable, Equatable {
        /// Text.
        case none
        /// After ESC.
        case start
        /// A control sequence (ESC [), until its final byte.
        case csi
        /// A string (OSC, DCS, APC, PM, SOS), until BEL or ESC \.
        case string
        /// ESC inside a string.
        case stringEnd
    }

    public private(set) var step: Step = .idle
    private var escape: Escape = .none

    public init() {}

    /// Bytes the session accepted: true when they are the probed key, one
    /// printable byte (its `terminal_key_sent` mark). Arms once.
    public mutating func sent(_ data: Data) -> Bool {
        guard case .idle = step, data.count == 1, let byte = data.first, (0x21...0x7E).contains(byte) else { return false }
        step = .sent(byte)
        escape = .none
        return true
    }

    /// An output batch handed to Ghostty: its echo when the key's byte is text in it.
    public mutating func fed(_ data: Data) {
        guard case .sent(let key) = step else { return }
        for byte in data {
            switch escape {
            case .none:
                if byte == 0x1B {
                    escape = .start
                } else if byte == key {
                    step = .fed(parsed: false)
                    return
                }
            case .start:
                switch byte {
                case 0x5B: escape = .csi // [
                case 0x5D, 0x50, 0x5F, 0x5E, 0x58: escape = .string // ] P _ ^ X
                case 0x20...0x2F: break // intermediates (ESC ( B)
                default: escape = .none
                }
            case .csi:
                if (0x40...0x7E).contains(byte) { escape = .none }
            case .string:
                if byte == 0x07 { escape = .none } else if byte == 0x1B { escape = .stringEnd }
            case .stringEnd:
                escape = byte == 0x5C ? .none : .string // ESC \
            }
        }
    }

    /// Ghostty parsed what it was fed.
    public mutating func processed() {
        guard case .fed(parsed: false) = step else { return }
        step = .fed(parsed: true)
    }

    /// A frame was presented: true when it is the echo's (its `terminal_echo_presented` mark).
    public mutating func presented() -> Bool {
        guard case .fed(parsed: true) = step else { return false }
        step = .done
        return true
    }
}
