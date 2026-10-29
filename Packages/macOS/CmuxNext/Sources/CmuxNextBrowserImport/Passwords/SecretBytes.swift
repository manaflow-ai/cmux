import CmuxNextCompat
public import Foundation

/// Bytes that must not outlive their use: an imported password or the key
/// that decrypts it (plans/cmux-next/browser.md, "Password import").
///
/// The bytes live in their own page-aligned allocation of whole pages (so
/// locking and unlocking one never touches another secret's pages), locked
/// out of swap where the system allows it, and are zeroed with `memset_s`
/// (which the compiler may not drop) before the allocation is freed. They are never a `String` or a
/// `Data`, never print (descriptions and mirrors are redacted), and are not
/// `Codable`, so they cannot reach a log, a crash report, telemetry or a file
/// by accident. Hand them on only through `withUnsafeBytes`, or check them in
/// place with `isValidUTF8`, `starts(with:)` and `matches(_:)`.
///
/// The count and the reads in progress are one ``State`` behind a `Mutex`: `zero()` empties the
/// bytes at once for new reads, and zeroes the memory when no `withUnsafeBytes` is reading it (the
/// last read to end does it), so a read never sees half-zeroed bytes. The lock is held only to
/// count, never while a read runs, so a read may ask for `count` or read another secret.
///
/// Memory safety: `address` and `size` name the one allocation `init` made, whole pages and page
/// aligned, fixed from init to deinit; deinit (or a failed fill, which then throws, so no method runs
/// after it) zeroes, unlocks and frees it once. `count` is at most the capacity `init` was asked for,
/// which is at most `size`. Every pointer use below relies on that.
@safe
public final class SecretBytes: Sendable {
    private struct State {
        /// The bytes in use (at most the capacity); 0 once zeroed.
        var count: Int
        /// `withUnsafeBytes` calls running now.
        var readers = 0
        /// `zero()` ran while reads were running: the last one to end zeroes the memory.
        var zeroWhenReadsEnd = false
    }

    /// The allocation's address as a bit pattern (a Sendable value) and its size in whole pages; both
    /// fixed from init to deinit.
    private let address: UInt
    private let size: Int
    private let locked: Bool
    private let state: Mutex<State>

    /// The bytes in use (at most the capacity).
    public var count: Int { state.withLock { $0.count } }

    /// A zeroed buffer of `capacity` bytes; `fill` writes into it and returns how many it used.
    @safe public init(capacity: Int, fill: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows {
        let page = getpagesize().widened
        let usable = max(capacity, 1)
        let size = (usable + page - 1) / page * page
        // SAFETY: a new allocation of `size` bytes (whole pages, at least one), owned here and freed
        // exactly once by wipe.
        let allocation = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: page)
        // SAFETY: writes zeros over exactly the `size` bytes just allocated.
        unsafe allocation.initializeMemory(as: UInt8.self, repeating: 0)
        // SAFETY: locks the allocation's `size` bytes; they stay allocated until wipe unlocks them.
        let locked = unsafe mlock(allocation.baseAddress, size) == 0
        let count: Int
        do {
            // `fill` sees exactly the capacity asked for, and its answer is clamped into it.
            // SAFETY: the view is the allocation's first `usable` bytes (usable <= size), valid for the
            // call; `fill`'s closure is not escaping, so it cannot keep the view.
            let used = try unsafe fill(UnsafeMutableRawBufferPointer(rebasing: allocation.prefix(usable)))
            count = min(max(used, 0), usable)
        } catch {
            // SAFETY: the allocation made above, freed once here; init throws, so nothing reads it after.
            unsafe SecretBytes.wipe(allocation, locked: locked)
            throw error
        }
        address = UInt(bitPattern: unsafe allocation.baseAddress)
        self.size = size
        self.locked = locked
        state = Mutex(State(count: count))
    }

    /// A copy of `bytes` (test fixtures and the Keychain reply, which arrives as `Data`).
    public convenience init(copying bytes: some Collection<UInt8>) {
        self.init(capacity: bytes.count) { buffer in
            // SAFETY: `buffer` holds max(bytes.count, 1) bytes, room for the bytes.count copied in.
            unsafe buffer.copyBytes(from: bytes)
            return bytes.count
        }
    }

    // SAFETY: the last holder is gone, so no read runs; the allocation is freed once here.
    deinit { unsafe Self.wipe(allocation, locked: locked) }

    /// Zeroes the bytes (once they have been handed on): empty at once for every new read, and the
    /// memory zeroed now, or when the reads running now end. The allocation goes at deinit.
    public func zero() {
        state.withLock { state in
            state.count = 0
            if state.readers == 0 {
                // SAFETY: no read is running (readers is 0 under the lock); the allocation is live (see the type).
                unsafe Self.clear(allocation)
            } else {
                state.zeroWhenReadsEnd = true
            }
        }
    }

    @safe public func withUnsafeBytes<R, E: Error>(_ body: (UnsafeRawBufferPointer) throws(E) -> R) throws(E) -> R {
        let count = state.withLock { state -> Int in
            state.readers += 1
            return state.count
        }
        defer { endRead() }
        // SAFETY: the view is the live allocation's first `count` bytes (count <= size), valid for the call and
        // not zeroed while it runs (zero() waits for the last read); `body` is not escaping, so it cannot keep it.
        return try unsafe body(UnsafeRawBufferPointer(rebasing: allocation.prefix(count)))
    }

    /// The bytes' address for handing many secrets to one C call. Valid only
    /// while this object is alive and not zeroed: keep it alive with `withExtendedLifetime`
    /// until the call returns, zero it only after, and never store the pointer.
    @unsafe public var unsafeBytesWhileAlive: UnsafeRawBufferPointer {
        unsafe UnsafeRawBufferPointer(rebasing: allocation.prefix(count))
    }

    /// Whether the bytes are UTF-8, checked in place: they never become a `String`.
    public var isValidUTF8: Bool {
        withUnsafeBytes { bytes in
            var decoder = UTF8()
            // SAFETY: the iterator reads `bytes` (the live first `count` bytes) one at a time and stops at
            // its end; it does not leave this closure.
            var iterator = unsafe bytes.makeIterator()
            // Each step reads at least one byte, so this ends within `bytes.count` steps.
            for _ in 0...bytes.count {
                switch unsafe decoder.decode(&iterator) {
                case .scalarValue: continue
                case .emptyInput: return true
                case .error: return false
                }
            }
            return false
        }
    }

    /// Whether the bytes begin with `prefix`, compared in place.
    public func starts(with prefix: [UInt8]) -> Bool {
        withUnsafeBytes { bytes in
            // SAFETY: reads `bytes` front to back, never past its end, while this closure runs.
            unsafe bytes.starts(with: prefix)
        }
    }

    /// Compares in time that depends only on the lengths.
    public func matches(_ other: SecretBytes) -> Bool {
        withUnsafeBytes { mine in
            other.withUnsafeBytes { theirs in
                guard mine.count == theirs.count else { return false }
                // Every byte pair is read (no early exit), so the time depends only on the count.
                // SAFETY: both views hold exactly the same count of bytes (checked above) and are valid while these
                // closures run; zip reads them front to back, never past either end.
                let difference = unsafe zip(mine, theirs).reduce(UInt8.zero) { $0 | ($1.0 ^ $1.1) }
                return difference == 0
            }
        }
    }

    public var isEmpty: Bool { count == 0 }

    /// The whole allocation, rebuilt from its address.
    @unsafe private var allocation: UnsafeMutableRawBufferPointer {
        unsafe UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(bitPattern: address), count: size)
    }

    /// One read ended: the last one zeroes the memory when `zero()` ran during the reads.
    private func endRead() {
        state.withLock { state in
            state.readers -= 1
            guard state.readers == 0, state.zeroWhenReadsEnd else { return }
            state.zeroWhenReadsEnd = false
            // SAFETY: the last read just ended (readers is 0 under the lock); the allocation is live (see the type).
            unsafe Self.clear(allocation)
        }
    }

    /// Zeroes all of `buffer`, the live allocation.
    @unsafe private static func clear(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let base = unsafe buffer.baseAddress else { return }
        let size = unsafe buffer.count
        // SAFETY: zeroes exactly the live allocation's `size` bytes.
        _ = unsafe memset_s(base, size, 0, size)
    }

    /// Zeroes, unlocks and frees the allocation; called once, from deinit or a failed fill.
    @unsafe private static func wipe(_ buffer: UnsafeMutableRawBufferPointer, locked: Bool) {
        guard let base = unsafe buffer.baseAddress else { return }
        let size = unsafe buffer.count
        unsafe clear(buffer)
        if locked { _ = unsafe munlock(base, size) }
        // SAFETY: frees the allocation once (the callers above run once per allocation).
        unsafe buffer.deallocate()
    }
}

extension SecretBytes: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
