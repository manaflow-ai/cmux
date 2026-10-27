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
/// Memory safety: `buffer` is the one allocation `init` made, whole pages and
/// page aligned. It stays allocated until `wipe` zeroes, frees and empties it;
/// `wipe` runs only from deinit or from a failed fill (which then throws, so no
/// method runs after it). `count` is at most the capacity `init` was asked
/// for, which is at most `buffer.count`. Every pointer use below relies on that.
@safe
public final class SecretBytes: @unchecked Sendable {
    private var buffer: UnsafeMutableRawBufferPointer
    private let locked: Bool
    /// The bytes in use (at most the capacity).
    public private(set) var count: Int

    /// A zeroed buffer of `capacity` bytes; `fill` writes into it and returns how many it used.
    @safe public init(capacity: Int, fill: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows {
        let page = Int(getpagesize())
        let usable = max(capacity, 1)
        let size = (usable + page - 1) / page * page
        // SAFETY: a new allocation of `size` bytes (whole pages, at least one), owned here and freed
        // exactly once by wipe.
        let allocation = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: page)
        // SAFETY: writes zeros over exactly the `size` bytes just allocated.
        unsafe allocation.initializeMemory(as: UInt8.self, repeating: 0)
        // SAFETY: stores the owned allocation; wipe frees it.
        unsafe buffer = allocation
        // SAFETY: locks the allocation's `size` bytes; they stay allocated until wipe unlocks them.
        locked = unsafe mlock(allocation.baseAddress, size) == 0
        count = 0
        do {
            // `fill` sees exactly the capacity asked for, and its answer is clamped into it.
            // SAFETY: the view is the allocation's first `usable` bytes (usable <= size), valid for the
            // call; `fill`'s closure is not escaping, so it cannot keep the view.
            let used = try unsafe fill(UnsafeMutableRawBufferPointer(rebasing: allocation[0..<usable]))
            count = min(max(used, 0), usable)
        } catch {
            wipe()
            throw error
        }
    }

    /// A copy of `bytes` (test fixtures and the Keychain reply, which arrives as `Data`).
    public convenience init(copying bytes: some Collection<UInt8>) {
        self.init(capacity: bytes.count) { buffer in
            // SAFETY: `buffer` holds max(bytes.count, 1) bytes, room for the bytes.count copied in.
            unsafe buffer.copyBytes(from: bytes)
            return bytes.count
        }
    }

    deinit { wipe() }

    /// Zeroes the bytes now (once they have been handed on); the allocation goes at deinit.
    public func zero() {
        // SAFETY: the allocation is live (see the type) or already emptied, which has no base address.
        guard let base = unsafe buffer.baseAddress else { return }
        let size = unsafe buffer.count
        // SAFETY: zeroes exactly the live allocation's `size` bytes.
        _ = unsafe memset_s(base, size, 0, size)
        count = 0
    }

    /// Zeroes, unlocks and frees the bytes once; later calls (deinit after a failed fill) do nothing.
    private func wipe() {
        // SAFETY: the allocation is live (see the type) or already emptied, which has no base address.
        guard let base = unsafe buffer.baseAddress else { return }
        let size = unsafe buffer.count
        // SAFETY: zeroes and unlocks exactly the live allocation's `size` bytes.
        _ = unsafe memset_s(base, size, 0, size)
        if locked { _ = unsafe munlock(base, size) }
        // SAFETY: frees the allocation once and empties `buffer`, so a second wipe returns above and no
        // later read finds the freed address.
        unsafe buffer.deallocate()
        unsafe buffer = UnsafeMutableRawBufferPointer(start: nil, count: 0)
        count = 0
    }

    @safe public func withUnsafeBytes<R, E: Error>(_ body: (UnsafeRawBufferPointer) throws(E) -> R) throws(E) -> R {
        // SAFETY: the view is the live allocation's first `count` bytes (count <= buffer.count), valid
        // for the call; `body` is not escaping, so it cannot keep the view.
        try unsafe body(UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
    }

    /// The bytes' address for handing many secrets to one C call. Valid only
    /// while this object is alive: keep it alive with `withExtendedLifetime`
    /// until the call returns, and never store the pointer.
    @unsafe public var unsafeBytesWhileAlive: UnsafeRawBufferPointer {
        unsafe UnsafeRawBufferPointer(rebasing: buffer[0..<count])
    }

    /// Whether the bytes are UTF-8, checked in place: they never become a `String`.
    public var isValidUTF8: Bool {
        withUnsafeBytes { bytes in
            var decoder = UTF8()
            // SAFETY: the iterator reads `bytes` (the live first `count` bytes) one at a time and stops at
            // its end; it does not leave this closure.
            var iterator = unsafe bytes.makeIterator()
            // Each step reads at least one byte, so this ends within `count` steps.
            for _ in 0...count {
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
        guard count == other.count else { return false }
        return withUnsafeBytes { mine in
            other.withUnsafeBytes { theirs in
                var difference: UInt8 = 0
                // SAFETY: both views hold exactly `count` bytes (checked equal above), so every index in
                // 0..<count is inside both; both are valid while these closures run.
                for index in 0..<count { difference |= unsafe mine[index] ^ theirs[index] }
                return difference == 0
            }
        }
    }

    public var isEmpty: Bool { count == 0 }
}

extension SecretBytes: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
