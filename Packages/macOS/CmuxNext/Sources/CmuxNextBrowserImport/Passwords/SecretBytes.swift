public import Foundation

/// Bytes that must not outlive their use: an imported password or the key
/// that decrypts it (plans/cmux-next/browser.md, "Password import").
///
/// The bytes live in their own allocation, locked out of swap where the
/// system allows it, and are zeroed with `memset_s` (which the compiler may
/// not drop) before the allocation is freed. They are never a `String` or a
/// `Data`, never print (descriptions and mirrors are redacted), and are not
/// `Codable`, so they cannot reach a log, a crash report, telemetry or a file
/// by accident. Hand them on only through `withUnsafeBytes`.
public final class SecretBytes: @unchecked Sendable {
    private let buffer: UnsafeMutableRawBufferPointer
    private let locked: Bool
    /// The bytes in use (at most the capacity).
    public private(set) var count: Int

    /// A zeroed buffer of `capacity` bytes; `fill` writes into it and returns how many it used.
    public init(capacity: Int, fill: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows {
        let size = max(capacity, 1)
        buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 16)
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        locked = mlock(buffer.baseAddress, size) == 0
        count = 0
        do {
            count = min(max(try fill(buffer), 0), size)
        } catch {
            wipe()
            throw error
        }
    }

    /// A copy of `bytes` (test fixtures and the Keychain reply, which arrives as `Data`).
    public convenience init(copying bytes: some Collection<UInt8>) {
        self.init(capacity: bytes.count) { buffer in
            buffer.copyBytes(from: bytes)
            return bytes.count
        }
    }

    deinit { wipe() }

    private func wipe() {
        guard let base = buffer.baseAddress else { return }
        _ = memset_s(base, buffer.count, 0, buffer.count)
        if locked { munlock(base, buffer.count) }
        buffer.deallocate()
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
    }

    /// The bytes' address for handing many secrets to one C call. Valid only
    /// while this object is alive: keep it alive with `withExtendedLifetime`
    /// until the call returns, and never store the pointer.
    public var unsafeBytesWhileAlive: UnsafeRawBufferPointer { UnsafeRawBufferPointer(rebasing: buffer[0..<count]) }

    /// Compares in time that depends only on the lengths.
    public func matches(_ other: SecretBytes) -> Bool {
        guard count == other.count else { return false }
        return withUnsafeBytes { mine in
            other.withUnsafeBytes { theirs in
                var difference: UInt8 = 0
                for index in 0..<mine.count { difference |= mine[index] ^ theirs[index] }
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
