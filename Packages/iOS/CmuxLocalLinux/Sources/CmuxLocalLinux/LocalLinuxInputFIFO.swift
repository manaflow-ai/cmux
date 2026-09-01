public import Foundation

/// A bounded-usage FIFO for bytes waiting on the non-blocking local PTY.
///
/// Ghostty can deliver one callback per byte, so shifting an array on every
/// dequeue makes a long paste quadratic. This ring keeps logical head and tail
/// positions separate from the backing storage. Partial writes advance the
/// head offset instead of rebuilding the remaining `Data`, so repeated EAGAIN
/// retries do not copy the same bytes.
public struct LocalLinuxInputFIFO: Sendable {
    private static let initialCapacity = 16

    private var storage: [Data?] = []
    private var headIndex = 0
    private var elementCount = 0
    private var headOffset = 0

    /// The number of bytes currently waiting in the FIFO.
    public private(set) var byteCount = 0

    /// Whether the FIFO has no queued bytes.
    public var isEmpty: Bool {
        elementCount == 0
    }

    /// Number of bytes remaining in the current logical head element.
    public var headByteCount: Int {
        guard elementCount > 0,
              let head = storage[headIndex] else { return 0 }
        return head.count - headOffset
    }

    /// A `Data` slice containing the current head remainder.
    ///
    /// `Data.SubSequence` is `Data`, so this shares the backing bytes until a
    /// caller mutates either value.
    public var headRemainder: Data {
        guard elementCount > 0,
              let head = storage[headIndex] else { return Data() }
        guard headOffset > 0 else { return head }
        let start = head.index(head.startIndex, offsetBy: headOffset)
        return head[start..<head.endIndex]
    }

    /// Creates an empty FIFO.
    public init() {}

    /// Adds one non-empty byte element to the tail.
    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        ensureCapacity()
        let tailIndex = (headIndex + elementCount) % storage.count
        storage[tailIndex] = data
        elementCount += 1
        byteCount += data.count
    }

    /// Consumes bytes from the current head without moving later entries.
    ///
    /// The caller must pass a count no greater than `headByteCount`.
    public mutating func consume(_ count: Int) {
        guard count > 0 else { return }
        guard elementCount > 0,
              let head = storage[headIndex] else {
            assertionFailure("cannot consume from an empty input FIFO")
            return
        }
        let available = head.count - headOffset
        guard count <= available else {
            assertionFailure("input FIFO consume exceeds head remainder")
            return
        }

        headOffset += count
        byteCount -= count
        guard headOffset == head.count else { return }

        storage[headIndex] = nil
        elementCount -= 1
        headOffset = 0
        if elementCount == 0 {
            headIndex = 0
            // A burst of one-byte callbacks can grow the ring to many slots.
            // Release that capacity after the burst is drained while retaining
            // a small baseline to avoid a reallocation per key.
            if storage.count > Self.initialCapacity {
                storage = Array(repeating: nil, count: Self.initialCapacity)
            }
        } else {
            headIndex = (headIndex + 1) % storage.count
        }
    }

    /// Removes every queued byte.
    public mutating func removeAll(keepingCapacity: Bool = false) {
        if keepingCapacity {
            for index in storage.indices {
                storage[index] = nil
            }
        } else {
            storage.removeAll(keepingCapacity: false)
        }
        headIndex = 0
        elementCount = 0
        headOffset = 0
        byteCount = 0
    }

    private mutating func ensureCapacity() {
        if storage.isEmpty {
            storage = Array(repeating: nil, count: Self.initialCapacity)
            return
        }
        guard elementCount == storage.count else { return }

        let oldStorage = storage
        let newCapacity = max(Self.initialCapacity, oldStorage.count * 2)
        var expanded = Array<Data?>(repeating: nil, count: newCapacity)
        for offset in 0..<elementCount {
            expanded[offset] = oldStorage[(headIndex + offset) % oldStorage.count]
        }
        storage = expanded
        headIndex = 0
    }
}
