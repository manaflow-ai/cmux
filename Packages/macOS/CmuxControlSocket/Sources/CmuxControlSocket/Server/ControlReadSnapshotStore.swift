internal import CmuxControlSocketAtomicsC
internal import os

/// An immutable publication of control-plane read results.
///
/// Entries contain typed call results without a request id. A socket worker
/// supplies the live request id when it encodes a hit, so snapshot reads retain
/// the v2 id-echo contract while avoiding a main-actor turn for every poll.
public struct ControlReadSnapshot: Sendable, Equatable {
    /// Monotonically increasing publication generation.
    public let generation: UInt64
    /// Results indexed by ``key(method:params:)``.
    public let responses: [String: ControlCallResult]

    /// Creates a snapshot.
    public init(
        generation: UInt64 = 0,
        responses: [String: ControlCallResult] = [:]
    ) {
        self.generation = generation
        self.responses = responses
    }

    /// Builds the canonical lookup key for a command and its typed params.
    ///
    /// Object keys are sorted recursively, so equivalent JSON objects map to
    /// one entry regardless of Foundation dictionary iteration order.
    public static func key(
        method: String,
        params: [String: JSONValue]
    ) -> String {
        method + "\u{1F}" + CanonicalJSON.string(.object(params))
    }

    private struct CanonicalJSON {
        static func string(_ value: JSONValue) -> String {
            switch value {
            case .null:
                return "null"
            case .bool(let value):
                return value ? "true" : "false"
            case .int(let value):
                return String(value)
            case .double(let value):
                return String(value)
            case .decimal(let value):
                return value
            case .string(let value):
                return "\"" + escape(value) + "\""
            case .array(let values):
                return "[" + values.map(string).joined(separator: ",") + "]"
            case .object(let values):
                return "{" + values.keys.sorted().map { key in
                    "\"" + escape(key) + "\":" + string(values[key]!)
                }.joined(separator: ",") + "}"
            }
        }

        private static func escape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
        }
    }
}

/// Publishes immutable control read snapshots for synchronous worker reads.
///
/// Readers are lock-free: an atomic reader count protects the lifetime of the
/// immutable box loaded from the atomic pointer. Writers exchange one pointer
/// and reclaim retired boxes only after the reader count reaches zero. The
/// short writer-only lock protects the retired list; it is never taken by a
/// socket read and never spans command execution, socket I/O, or an actor hop.
/// C11 atomics are used instead of `Synchronization.Atomic` because this
/// package supports macOS 14.
public final class ControlReadSnapshotStore: @unchecked Sendable {
    private final class SnapshotBox: @unchecked Sendable {
        let snapshot: ControlReadSnapshot

        init(_ snapshot: ControlReadSnapshot) {
            self.snapshot = snapshot
        }
    }

    private struct RetiredState {
        var boxes: [Unmanaged<SnapshotBox>] = []
    }

    // The pointers are allocated once and all pointee accesses go through the
    // C11 atomic functions. This is the safety argument for the unchecked
    // Sendable wrapper: Swift never performs an overlapping access to storage.
    private let pointerStorage: UnsafeMutablePointer<CmuxControlSocketAtomicPointerStorage>
    private let readerCountStorage: UnsafeMutablePointer<CmuxControlSocketAtomicCounterStorage>
    /// Writer-only reclamation bookkeeping; lock-free reads never touch it.
    private let retiredState: OSAllocatedUnfairLock<RetiredState>

    /// Creates an empty store.
    public init(initialSnapshot: ControlReadSnapshot = ControlReadSnapshot()) {
        pointerStorage = .allocate(capacity: 1)
        readerCountStorage = .allocate(capacity: 1)
        retiredState = OSAllocatedUnfairLock(initialState: RetiredState())
        CmuxControlSocketAtomicPointerInitialize(pointerStorage, 0)
        CmuxControlSocketAtomicCounterInitialize(readerCountStorage, 0)
        publish(initialSnapshot)
    }

    deinit {
        let current = CmuxControlSocketAtomicPointerExchange(pointerStorage, 0)
        let readers = CmuxControlSocketAtomicCounterLoad(readerCountStorage)
        // Store lifetime is owned by the app and outlives admitted socket
        // tasks. If a caller violates that contract, leaking is safer than
        // releasing a box a reader may still be copying.
        if readers == 0, current != 0 {
            Self.release(current)
        }
        if readers == 0 {
            retiredState.withLock { retired in
                for box in retired.boxes {
                    box.release()
                }
                retired.boxes.removeAll()
            }
        }
        if readers == 0 {
            pointerStorage.deallocate()
            readerCountStorage.deallocate()
        } // Otherwise intentionally leak the atomic cells with the boxes.
    }

    /// Returns the most recently published immutable snapshot.
    public func read() -> ControlReadSnapshot {
        readUnlocked()
    }

    private func readUnlocked() -> ControlReadSnapshot {
        CmuxControlSocketAtomicCounterIncrement(readerCountStorage)
        let rawPointer = CmuxControlSocketAtomicPointerLoadAcquire(pointerStorage)
        let snapshot: ControlReadSnapshot
        if rawPointer == 0 {
            snapshot = ControlReadSnapshot()
        } else {
            snapshot = Self.box(from: rawPointer).takeUnretainedValue().snapshot
        }
        CmuxControlSocketAtomicCounterDecrement(readerCountStorage)
        return snapshot
    }

    /// Replaces the current snapshot.
    ///
    /// - Parameter snapshot: The fully built value. Build it before calling
    ///   this method so the publication section stays short.
    public func publish(_ snapshot: ControlReadSnapshot) {
        retiredState.withLock { retired in
            publishLocked(snapshot, retired: &retired)
        }
    }

    /// Looks up one command result without an actor hop.
    public func response(
        method: String,
        params: [String: JSONValue]
    ) -> ControlCallResult? {
        let key = ControlReadSnapshot.key(method: method, params: params)
        CmuxControlSocketAtomicCounterIncrement(readerCountStorage)
        let rawPointer = CmuxControlSocketAtomicPointerLoadAcquire(pointerStorage)
        let result = rawPointer == 0
            ? nil
            : Self.box(from: rawPointer).takeUnretainedValue().snapshot.responses[key]
        CmuxControlSocketAtomicCounterDecrement(readerCountStorage)
        return result
    }

    /// Publishes/replaces one response and advances the generation.
    public func publishResponse(
        method: String,
        params: [String: JSONValue],
        result: ControlCallResult
    ) {
        let key = ControlReadSnapshot.key(method: method, params: params)
        retiredState.withLock { retired in
            var snapshot = readUnlocked()
            var responses = snapshot.responses
            responses[key] = result
            snapshot = ControlReadSnapshot(
                generation: snapshot.generation &+ 1,
                responses: responses
            )
            publishLocked(snapshot, retired: &retired)
        }
    }

    private func publishLocked(
        _ snapshot: ControlReadSnapshot,
        retired: inout RetiredState
    ) {
        let box = Unmanaged.passRetained(SnapshotBox(snapshot))
        let newPointer = UInt(bitPattern: box.toOpaque())
        let oldPointer = CmuxControlSocketAtomicPointerExchange(pointerStorage, newPointer)
        guard oldPointer != 0 else { return }
        retired.boxes.append(Self.box(from: oldPointer))
        guard CmuxControlSocketAtomicCounterLoad(readerCountStorage) == 0 else { return }
        for retiredBox in retired.boxes {
            retiredBox.release()
        }
        retired.boxes.removeAll(keepingCapacity: true)
    }

    private static func box(from rawPointer: UInt) -> Unmanaged<SnapshotBox> {
        Unmanaged<SnapshotBox>.fromOpaque(
            UnsafeRawPointer(bitPattern: rawPointer)!
        )
    }

    private static func release(_ rawPointer: UInt) {
        box(from: rawPointer).release()
    }
}
