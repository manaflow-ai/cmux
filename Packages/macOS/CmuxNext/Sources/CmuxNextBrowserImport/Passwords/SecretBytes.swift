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
/// by accident. Hand them on only through `withUnsafeBytes`.
///
/// The count and the reads in progress are one ``State`` behind a `Mutex`: `zero()` empties the
/// bytes at once for new reads, and zeroes the memory when no `withUnsafeBytes` is reading it (the
/// last read to end does it), so a read never sees half-zeroed bytes. The lock is held only to
/// count, never while a read runs, so a read may ask for `count` or read another secret.
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
    public init(capacity: Int, fill: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows {
        let page = Int(getpagesize())
        let size = (max(capacity, 1) + page - 1) / page * page
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: page)
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        let locked = mlock(buffer.baseAddress, size) == 0
        let count: Int
        do {
            // `fill` sees exactly the capacity asked for.
            count = min(max(try fill(UnsafeMutableRawBufferPointer(rebasing: buffer[0..<max(capacity, 1)])), 0), max(capacity, 1))
        } catch {
            SecretBytes.wipe(buffer, locked: locked)
            throw error
        }
        address = UInt(bitPattern: buffer.baseAddress)
        self.size = size
        self.locked = locked
        state = Mutex(State(count: count))
    }

    /// A copy of `bytes` (test fixtures and the Keychain reply, which arrives as `Data`).
    public convenience init(copying bytes: some Collection<UInt8>) {
        self.init(capacity: bytes.count) { buffer in
            buffer.copyBytes(from: bytes)
            return bytes.count
        }
    }

    deinit { Self.wipe(allocation, locked: locked) }

    /// Zeroes the bytes (once they have been handed on): empty at once for every new read, and the
    /// memory zeroed now, or when the reads running now end. The allocation goes at deinit.
    public func zero() {
        state.withLock { state in
            state.count = 0
            if state.readers == 0 {
                Self.clear(allocation)
            } else {
                state.zeroWhenReadsEnd = true
            }
        }
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        let count = state.withLock { state -> Int in
            state.readers += 1
            return state.count
        }
        defer { endRead() }
        return try body(UnsafeRawBufferPointer(rebasing: allocation[0..<count]))
    }

    /// The bytes' address for handing many secrets to one C call. Valid only
    /// while this object is alive and not zeroed: keep it alive with `withExtendedLifetime`
    /// until the call returns, zero it only after, and never store the pointer.
    public var unsafeBytesWhileAlive: UnsafeRawBufferPointer { UnsafeRawBufferPointer(rebasing: allocation[0..<count]) }

    /// Compares in time that depends only on the lengths.
    public func matches(_ other: SecretBytes) -> Bool {
        withUnsafeBytes { mine in
            other.withUnsafeBytes { theirs in
                guard mine.count == theirs.count else { return false }
                var difference: UInt8 = 0
                for index in 0..<mine.count { difference |= mine[index] ^ theirs[index] }
                return difference == 0
            }
        }
    }

    public var isEmpty: Bool { count == 0 }

    /// The whole allocation, rebuilt from its address.
    private var allocation: UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(bitPattern: address), count: size)
    }

    /// One read ended: the last one zeroes the memory when `zero()` ran during the reads.
    private func endRead() {
        state.withLock { state in
            state.readers -= 1
            guard state.readers == 0, state.zeroWhenReadsEnd else { return }
            state.zeroWhenReadsEnd = false
            Self.clear(allocation)
        }
    }

    private static func clear(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let base = buffer.baseAddress else { return }
        _ = memset_s(base, buffer.count, 0, buffer.count)
    }

    /// Zeroes, unlocks and frees the allocation.
    private static func wipe(_ buffer: UnsafeMutableRawBufferPointer, locked: Bool) {
        guard let base = buffer.baseAddress else { return }
        clear(buffer)
        if locked { munlock(base, buffer.count) }
        buffer.deallocate()
    }
}

extension SecretBytes: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
