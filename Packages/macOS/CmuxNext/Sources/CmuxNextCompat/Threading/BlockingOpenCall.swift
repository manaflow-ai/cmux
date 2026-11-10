/// The checked blocking call the main thread is inside right now, for the hang watcher to name
/// (Chrome's `HangWatcher` reports the `ScopedBlockingCall` a hung thread is in).
///
/// ``blockingCall(_:fileID:line:_:)`` writes it on the main thread around the blocking primitive; the
/// watchdog thread reads it while the main thread is suspended for a stack sample, or at a hang
/// checkpoint. Two atomics of the process's detector table, no lock and no allocation on either side, in the
/// builds with the detector (Debug, bench, Nightly); in Release ``current()`` is always ``none``. A nested
/// checked call replaces the outer one until it returns.
public struct BlockingOpenCall: Sendable, Equatable {
    /// The call site's `#fileID` text: static data, valid for the life of the process.
    public let fileID: UInt
    /// The site's line, its `#fileID` length and the ``BlockingKind`` index, packed (``pack``).
    public let packed: UInt64

    /// A call read back from its two words (``fileID`` and ``packed`` of a call ``current()`` returned), so a
    /// reader that must not allocate can keep them in atomics of its own.
    public init(fileID: UInt, packed: UInt64) {
        self.fileID = fileID
        self.packed = packed
    }

    /// No checked call open.
    public static let none = BlockingOpenCall(fileID: 0, packed: 0)

    /// The call open on the main thread now. Two atomic loads, so the watchdog may call it while the main
    /// thread is suspended. A call that opened or closed between the loads reads as ``none``.
    public static func current() -> BlockingOpenCall {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let table = BlockingViolationTable.shared  // never a test's scoped table: this is the real main thread
        let before = table.openFileID.load(ordering: .acquiring)
        let packed = table.openPacked.load(ordering: .acquiring)
        guard before != 0, table.openFileID.load(ordering: .acquiring) == before else { return .none }
        return BlockingOpenCall(fileID: before, packed: packed)
        #else
        return .none
        #endif
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS

    /// Opens `kind` at `fileID`:`line` and returns the call it replaced. Main thread only.
    @usableFromInline
    static func enter(_ kind: BlockingKind, fileID: StaticString, line: UInt) -> BlockingOpenCall {
        let previous = current()
        guard fileID.hasPointerRepresentation else { return previous }
        let address = UInt(bitPattern: fileID.utf8Start)
        open(BlockingOpenCall(fileID: address, packed: pack(kind, length: fileID.utf8CodeUnitCount, line: line)))
        return previous
    }

    /// Restores the call ``enter(_:fileID:line:)`` replaced. Main thread only.
    @usableFromInline
    static func leave(_ previous: BlockingOpenCall) {
        open(previous)
    }

    /// The file ID is cleared first and set last, so a reader that sees the same nonzero file ID before and
    /// after its load of `packed` read the `packed` written with it.
    private static func open(_ call: BlockingOpenCall) {
        let table = BlockingViolationTable.shared
        table.openFileID.store(0, ordering: .releasing)
        table.openPacked.store(call.packed, ordering: .releasing)
        table.openFileID.store(call.fileID, ordering: .releasing)
    }
    #endif

    /// Line in the high 32 bits, the `#fileID` length in the next 16, the kind's index in the low 8.
    static func pack(_ kind: BlockingKind, length: Int, line: UInt) -> UInt64 {
        let index = UInt64(BlockingKind.allCases.firstIndex(of: kind) ?? 0)
        return UInt64(truncatingIfNeeded: line) << 32 | UInt64(min(length, 0xFFFF)) << 16 | index
    }

    /// What the call waits on; nil for ``none``.
    public var kind: BlockingKind? {
        guard fileID != 0 else { return nil }
        let index = Int(packed & 0xFF)
        return BlockingKind.allCases.indices.contains(index) ? BlockingKind.allCases[index] : nil
    }

    /// `CmuxNextFiles/FileStore.swift:42`; nil for ``none``.
    public var location: String? {
        guard fileID != 0, let start = UnsafePointer<UInt8>(bitPattern: fileID) else { return nil }
        let length = Int((packed >> 16) & 0xFFFF)
        let file = String(decoding: UnsafeBufferPointer(start: start, count: length), as: UTF8.self)
        return "\(file):\(packed >> 32)"
    }

    /// `file-io at CmuxNextFiles/FileStore.swift:42`; nil for ``none``.
    public var summary: String? {
        guard let kind, let location else { return nil }
        return "\(kind.rawValue) at \(location)"
    }
}
