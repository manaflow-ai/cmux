import Foundation

/// Session output waiting for the terminal screen, drained once per display
/// frame (`TerminalViewController`'s output pump) instead of once per chunk.
///
/// - Bytes and alternate screen switches keep their order: a switch is taken
///   only once every byte before it was taken.
/// - Each frame takes at most `budget` bytes in one piece, so the main
///   thread's share of a frame is bounded however fast output arrives, and
///   Ghostty parses one batch per frame.
/// - Above `highWater` pending bytes the screen asks the session to pause;
///   below `lowWater` it resumes (``isOverHighWater``, ``isUnderLowWater``).
public struct TerminalOutputQueue: Sendable {
    public enum Step: Equatable, Sendable {
        case bytes(Data)
        case alternateScreen(Bool)
        /// The Mac's grid for the bytes after it.
        case hostGrid(columns: Int, rows: Int)
    }

    private enum Item: Sendable {
        case bytes([Data])
        case alternateScreen(Bool)
        case hostGrid(columns: Int, rows: Int)
    }

    /// Bytes handed to Ghostty per frame. Ghostty parses on its own queue, so
    /// this bounds latency and lock hold time, not main-thread work.
    public static let frameBudget = 256 << 10
    /// The batch for a frame. Ghostty holds its terminal lock while it parses
    /// a batch, and the main thread takes the same lock for a viewport request
    /// and the row reads, so a large batch stalls a drag or a fling.
    public static func budget(interacting: Bool) -> Int {
        interacting ? interactingBudget : frameBudget
    }
    /// 16 KB parses in well under a millisecond, and 16 KB a frame is still
    /// 1.9 MB/s at 120 Hz.
    public static let interactingBudget = 16 << 10
    public static let highWater = 8 << 20
    public static let lowWater = 2 << 20

    private var items: [Item] = []
    /// Offset into the first chunk of the first `.bytes` item already taken.
    private var headOffset = 0
    public private(set) var pendingBytes = 0

    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    public var isOverHighWater: Bool { pendingBytes > Self.highWater }
    public var isUnderLowWater: Bool { pendingBytes < Self.lowWater }

    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        pendingBytes += data.count
        if case .bytes(var chunks)? = items.last {
            items.removeLast()
            chunks.append(data)
            items.append(.bytes(chunks))
        } else {
            items.append(.bytes([data]))
        }
    }

    public mutating func append(alternateScreen on: Bool) {
        items.append(.alternateScreen(on))
    }

    /// The Mac's grid became `columns` x `rows` here: taken once every byte
    /// before it was taken, so no byte is drawn at a grid it was not written for.
    public mutating func append(hostGrid columns: Int, rows: Int) {
        items.append(.hostGrid(columns: columns, rows: rows))
    }

    /// The next step for this frame: up to `budget` bytes joined into one
    /// piece, or the alternate screen switch at the front.
    public mutating func next(budget: Int = frameBudget) -> Step? {
        guard let first = items.first else { return nil }
        switch first {
        case .alternateScreen(let on):
            items.removeFirst()
            return .alternateScreen(on)
        case .hostGrid(let columns, let rows):
            items.removeFirst()
            return .hostGrid(columns: columns, rows: rows)
        case .bytes(var chunks):
            var out = Data()
            var room = max(1, budget)
            var taken = 0
            while room > 0, taken < chunks.count {
                let chunk = chunks[taken]
                let start = chunk.startIndex + headOffset
                let available = chunk.endIndex - start
                if available <= room {
                    out.append(chunk[start..<chunk.endIndex])
                    room -= available
                    headOffset = 0
                    taken += 1
                } else {
                    out.append(chunk[start..<start + room])
                    headOffset += room
                    room = 0
                }
            }
            chunks.removeFirst(taken)
            if chunks.isEmpty {
                items.removeFirst()
            } else {
                items[0] = .bytes(chunks)
            }
            pendingBytes -= out.count
            return .bytes(out)
        }
    }

    /// Drops everything (the session restarted).
    public mutating func removeAll() {
        items.removeAll()
        headOffset = 0
        pendingBytes = 0
    }
}
