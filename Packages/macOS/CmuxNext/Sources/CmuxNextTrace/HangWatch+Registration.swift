extension HangWatch {
    /// What a registered thread runs. The raw values are shared with the Rust `cmux-hang-watch` crate.
    public enum ThreadKind: UInt8, Sendable, CaseIterable {
        /// The main thread.
        case main = 1
        /// A socket or PTY reader or writer (bounded I/O only; the wait itself stays outside the scope).
        case io = 2
        /// A serial work lane (``registerLane(_:)`` registers these).
        case lane = 3
        /// A renderer thread (Ghostty's, the remote view's Metal renderer).
        case renderer = 4
        /// A thread-pool worker (a tokio worker, a `BackgroundWork` thread).
        case pool = 5
        /// A control-socket handler.
        case control = 6
    }

    /// A registered slot: its index in the slot table and the generation that tells a reused slot apart.
    public struct Registration: Sendable, Hashable {
        /// The slot's index.
        public let slot: UInt32
        /// The slot's generation when it was registered (0: no slot; its scopes watch nothing).
        public let generation: UInt32

        /// The registration in one word, the generation above the slot, for a holder that keeps it in an
        /// atomic (``init(packed:)`` reads it back). Never 0: a refused registration's slot is `.max`.
        public var packed: UInt64 { UInt64(generation) << 32 | UInt64(slot) }
    }
}

extension HangWatch.Registration {
    /// The registration whose ``packed`` word is `packed`.
    public init(packed: UInt64) {
        self.init(slot: UInt32(truncatingIfNeeded: packed), generation: UInt32(truncatingIfNeeded: packed >> 32))
    }
}

extension HangWatch {
    /// A literal's address (48 bits) and length (16 bits) in one word; 0 for a one-scalar literal.
    static func pack(_ name: StaticString) -> UInt64 {
        guard name.hasPointerRepresentation else { return 0 }
        return UInt64(truncatingIfNeeded: UInt(bitPattern: name.utf8Start)) & 0xFFFF_FFFF_FFFF
            | UInt64(clamping: min(name.utf8CodeUnitCount, 0xFFFF)) << 48
    }

    static func unpack(_ packed: UInt64) -> String {
        guard let start = UnsafePointer<UInt8>(bitPattern: UInt(truncatingIfNeeded: packed & 0xFFFF_FFFF_FFFF)) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: start, count: Int(truncatingIfNeeded: packed >> 48)), as: UTF8.self)
    }

    static func nanos(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }
        let (whole, overflow) = UInt64(clamping: seconds).multipliedReportingOverflow(by: 1_000_000_000)
        let (sum, carry) = whole.addingReportingOverflow(UInt64(clamping: attoseconds / 1_000_000_000))
        return overflow || carry ? .max : sum
    }
}
