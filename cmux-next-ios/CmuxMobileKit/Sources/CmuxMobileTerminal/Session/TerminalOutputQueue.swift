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
        /// The device that set the Mac's grid, from here on (nil: this phone, or unknown).
        case hostGridOwner(String?)
    }

    private enum Item: Sendable {
        case bytes([Data])
        case alternateScreen(Bool)
        /// `stale`: the Mac's answer to a resize the phone asked for before
        /// its newest one (that one's answer is still coming).
        case hostGrid(columns: Int, rows: Int, stale: Bool)
        case hostGridOwner(String?)
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

    /// A switch off the alternate screen is queued (a replay that leaves it).
    public var leavesAlternateScreen: Bool {
        items.contains { if case .alternateScreen(false) = $0 { true } else { false } }
    }

    /// The Mac's grid change at the front, when that is the next step.
    public var nextHostGrid: (columns: Int, rows: Int)? {
        guard case .hostGrid(let columns, let rows, _)? = items.first else { return nil }
        return (columns, rows)
    }
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
    public mutating func append(hostGrid columns: Int, rows: Int, stale: Bool = false) {
        items.append(.hostGrid(columns: columns, rows: rows, stale: stale))
    }

    /// The device that sets the Mac's grid changed here: taken in order with
    /// the grid events, so the note never names a new owner next to the old grid.
    public mutating func append(hostGridOwner name: String?) {
        items.append(.hostGridOwner(name))
    }

    /// The next step for this frame: up to `budget` bytes joined into one
    /// piece, or the alternate screen switch at the front.
    public mutating func next(budget: Int = frameBudget) -> Step? {
        guard let first = items.first else { return nil }
        switch first {
        case .alternateScreen(let on):
            items.removeFirst()
            return .alternateScreen(on)
        case .hostGrid(let columns, let rows, _):
            items.removeFirst()
            return .hostGrid(columns: columns, rows: rows)
        case .hostGridOwner(let name):
            items.removeFirst()
            return .hostGridOwner(name)
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

    /// The grid change at the front answers a resize older than the
    /// newest one: the queue waits there for the newest answer.
    public var nextHostGridIsStale: Bool {
        guard case .hostGrid(_, _, let stale)? = items.first else { return false }
        return stale
    }

    /// A newer resize went out: every answer still queued is an older one's.
    public mutating func markGridsStale() {
        for index in items.indices {
            if case .hostGrid(let columns, let rows, false) = items[index] { items[index] = .hostGrid(columns: columns, rows: rows, stale: true) }
        }
    }

    /// The newest answer is not coming (its wait ran out): the queued
    /// answers go to the screen in order.
    public mutating func clearStale() {
        for index in items.indices {
            if case .hostGrid(let columns, let rows, true) = items[index] { items[index] = .hostGrid(columns: columns, rows: rows, stale: false) }
        }
    }

    /// The newest answer did not come: only the last stale answer queued
    /// stays (the older ones' resets would end its replay's count early).
    public mutating func keepLastStaleAnswer() {
        guard let last = items.lastIndex(where: { if case .hostGrid(_, _, true) = $0 { true } else { false } }),
              let first = items[..<last].firstIndex(where: { if case .hostGrid(_, _, true) = $0 { true } else { false } }) else { return }
        var dropped = 0
        var kept: [Item] = []
        for item in items[first..<last] {
            switch item {
            case .bytes(let chunks): dropped += chunks.reduce(0) { $0 + $1.count }
            case .hostGrid: break
            case .alternateScreen, .hostGridOwner: kept.append(item)
            }
        }
        items.replaceSubrange(first..<last, with: kept)
        pendingBytes -= dropped
    }

    /// The newest answer starts here (the grid change just queued): the
    /// stale answers queued before it (a grid change, its mirror reset and
    /// replay, and any bytes after them) are dropped, because its own reset
    /// clears whatever they would draw. Mode switches and grid owners stay,
    /// in order. Returns the bytes dropped.
    @discardableResult
    public mutating func dropStaleAnswers() -> Int {
        guard case .hostGrid(_, _, false)? = items.last else { return 0 }
        let last = items.count - 1
        guard let first = items[..<last].firstIndex(where: { if case .hostGrid(_, _, true) = $0 { true } else { false } }) else { return 0 }
        var dropped = 0
        var kept: [Item] = []
        for item in items[first..<last] {
            switch item {
            case .bytes(let chunks): dropped += chunks.reduce(0) { $0 + $1.count }
            case .hostGrid: break
            case .alternateScreen, .hostGridOwner: kept.append(item)
            }
        }
        items.replaceSubrange(first..<last, with: kept)
        pendingBytes -= dropped
        return dropped
    }

    /// Drops everything (the session restarted).
    public mutating func removeAll() {
        items.removeAll()
        headOffset = 0
        pendingBytes = 0
    }
}
