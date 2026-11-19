import Foundation

/// The launch marks' first terminal key (`LaunchMarks`: `terminal_key_sent`,
/// `terminal_echo_presented`): the first printable byte the person types, then
/// the first output batch that holds it, then the frame presented after Ghostty
/// parsed that batch. One key per process; after it every call returns at once,
/// so its cost stays constant however long the session runs.
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

    public private(set) var step: Step = .idle

    public init() {}

    /// Bytes typed: true when this is the first key (its `terminal_key_sent` mark).
    public mutating func sent(_ data: Data) -> Bool {
        guard case .idle = step, let byte = data.first(where: { (0x21...0x7E).contains($0) }) else { return false }
        step = .sent(byte)
        return true
    }

    /// An output batch handed to Ghostty.
    public mutating func fed(_ data: Data) {
        guard case .sent(let byte) = step, data.contains(byte) else { return }
        step = .fed(parsed: false)
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
