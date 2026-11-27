import Foundation
import CmuxNextCompat

/// The newest bytes a terminal sent its program (keys, IME text, pastes, its own reports), for
/// Toggle Terminal and Chat's draft carry (Leo, 2026-11-12: two live views of one session). Only
/// recorded here: reading the input line out of them is Rust's (cmux-window-rules `tabs::draft`).
/// Ghostty's IO thread records, the main actor reads; at most ``cap`` bytes, the newest kept.
public nonisolated final class TerminalTypedTail: Sendable {
    public static let cap = 16 * 1024

    private struct Tail {
        var bytes: [UInt8] = []
        var truncated = false
    }

    private let tail = Mutex(Tail())
    private let cap: Int

    public init(cap: Int = TerminalTypedTail.cap) {
        self.cap = cap
    }

    /// The bytes, oldest first, and whether older ones were dropped.
    public var read: (bytes: [UInt8], truncated: Bool) {
        tail.withLock { ($0.bytes, $0.truncated) }
    }

    /// No byte since the session started: nothing typed, so no draft.
    public var isEmpty: Bool {
        tail.withLock { $0.bytes.isEmpty && !$0.truncated }
    }

    func record(_ data: Data) {
        tail.withLock { tail in
            tail.bytes.append(contentsOf: data)
            if tail.bytes.count > cap {
                tail.bytes.removeFirst(tail.bytes.count - cap)
                tail.truncated = true
            }
        }
    }

    /// Input the bytes do not show went out (a file paste the daemon types): what came before no
    /// longer says what the input holds.
    func forget() {
        tail.withLock { $0 = Tail(bytes: [], truncated: true) }
    }
}
