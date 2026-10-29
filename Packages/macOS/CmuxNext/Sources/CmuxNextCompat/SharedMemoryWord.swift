internal import Atomics

/// A 64-bit word that another process writes in memory both map (a POSIX shared-memory frame
/// ring, read only here). ``loadAcquiring()`` reads it with acquire ordering: the reads after it
/// see at least what the writer stored before its release store of the word. One hardware load
/// (`ldar` on arm64), so it is safe on a read-only mapping. The address must be 8-byte aligned.
public nonisolated struct SharedMemoryWord {
    private let address: UnsafeRawPointer

    public init(_ address: UnsafeRawPointer) {
        self.address = address
    }

    public func loadAcquiring() -> UInt64 {
        let word = UnsafeMutableRawPointer(mutating: address).assumingMemoryBound(to: UInt64.AtomicRepresentation.self)
        return UnsafeAtomic<UInt64>(at: word).load(ordering: .acquiring)
    }

    /// The seqlock check after plain reads of the data the word guards: an acquire fence first, so
    /// none of those reads can move after this load (an acquire load alone orders only what follows it).
    public func loadAfterReads() -> UInt64 {
        atomicMemoryFence(ordering: .acquiring)
        let word = UnsafeMutableRawPointer(mutating: address).assumingMemoryBound(to: UInt64.AtomicRepresentation.self)
        return UnsafeAtomic<UInt64>(at: word).load(ordering: .relaxed)
    }
}
