public import Atomics

/// A 64-bit word in memory another process writes: a shared mapping such as
/// the daemon's terminal output ring (plans/cmux-next/app-daemon-connection-DESIGN.md
/// section 4.2). Reads are single hardware atomic loads, so a reader never
/// sees a torn value, with the ordering the call names.
///
/// The word must be 8-byte aligned and stay mapped while the value is used;
/// the owner of the mapping keeps it alive (the value holds only the address).
///
/// ```swift
/// let reserve = SharedMemoryWord(base + 32)
/// SharedMemoryWord.acquireFence()  // after reading the bytes the word guards
/// let lapped = reserve.load(ordering: .relaxed) > start + capacity
/// ```
public struct SharedMemoryWord: Sendable {
    /// The word's address as an integer (a pointer is not `Sendable`); the
    /// mapping's owner keeps the memory alive (above).
    private let address: UInt

    /// The word at `address` (8-byte aligned, inside a live mapping).
    public init(_ address: UnsafeRawPointer) {
        self.address = UInt(bitPattern: address)
    }

    /// The word's current value.
    public func load(ordering: AtomicLoadOrdering) -> UInt64 {
        // Never nil: `address` is the bit pattern of the non-null pointer init took.
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return 0 }
        let word = UnsafeAtomic<UInt64>(at: pointer.assumingMemoryBound(to: UInt64.AtomicRepresentation.self))
        return switch ordering {
        case .relaxed: word.load(ordering: .relaxed)
        case .acquiring: word.load(ordering: .acquiring)
        case .sequentiallyConsistent: word.load(ordering: .sequentiallyConsistent)
        }
    }

    /// Orders every read before it before every read after it: read the
    /// guarded bytes, fence, then load the word that says whether they were
    /// overwritten meanwhile (the seqlock reader's check).
    public static func acquireFence() {
        atomicMemoryFence(ordering: .acquiring)
    }
}
