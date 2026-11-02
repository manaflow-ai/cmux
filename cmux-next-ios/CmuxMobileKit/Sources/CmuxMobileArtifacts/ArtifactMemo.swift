import Foundation

/// Values made once per artifact this session (grid thumbnails), by artifact id and kind, so an
/// artifact that moves in the list or is referenced again keeps its value. An edit is new content:
/// an "Edited" detail is part of the key, so a file the agent changed again gets a new thumbnail. An `NSCache`, so memory
/// pressure evicts entries. A make runs once per key, shared by every tile asking for it, and is
/// cancelled when the last of them goes (scrolled away). Cancelled or thrown
/// loads are never cached; a successfully rendered `nil` (nothing to preview)
/// is a stable answer and can be cached.
final class ArtifactMemo<Value: Sendable>: @unchecked Sendable {
    private final class Entry {
        let value: Value?
        init(_ value: Value?) { self.value = value }
    }

    private let cache = NSCache<NSString, Entry>()
    private let cost: @Sendable (Value?) -> Int
    private let lock = NSLock()
    private var makes = 0

    init(costLimit: Int, cost: @escaping @Sendable (Value?) -> Int = { _ in 1 }) {
        cache.totalCostLimit = costLimit
        self.cost = cost
    }

    /// Makes started (tests read it).
    var makesStarted: Int { lock.withLock { makes } }

    static func key(_ artifact: TerminalArtifact) -> NSString {
        let edit = artifact.detail.flatMap { $0.hasPrefix("Edited") ? $0 : nil } ?? ""
        return "\(artifact.kind.rawValue)|\(artifact.id)|\(edit)" as NSString
    }

    /// A value already made (`.some(nil)`: known to have none), without making it.
    func cached(_ artifact: TerminalArtifact) -> Value?? {
        cache.object(forKey: Self.key(artifact)).map(\.value)
    }

    /// One make in progress: its generation (a make started after a cancelled one is a new
    /// one), its task and the callers waiting on it.
    private struct Make {
        let id: Int
        let task: Task<Value?, Never>
        var waiters: Int
    }

    /// Makes in progress, by key: a second ask joins the first.
    private var running: [String: Make] = [:]
    private var nextID = 0

    /// A caller's place in a make, left exactly once (its make ended, or it was cancelled).
    private final class Seat: @unchecked Sendable {
        var left = false
    }

    func value(for artifact: TerminalArtifact, make: @escaping @Sendable (TerminalArtifact) async throws -> Value?) async -> Value? {
        if let cached = cached(artifact) { return cached }
        let key = Self.key(artifact) as String
        let (id, task): (Int, Task<Value?, Never>) = lock.withLock {
            if var joined = running[key] {
                joined.waiters += 1
                running[key] = joined
                return (joined.id, joined.task)
            }
            makes += 1
            nextID += 1
            let id = nextID
            let task = Task<Value?, Never>(priority: .utility) { [weak self] in
                do {
                    let value = try await make(artifact)
                    self?.finish(value, key: key, id: id, record: !Task.isCancelled)
                    return value
                } catch {
                    // An offline Mac, permission error or cancelled SwiftUI
                    // tile is temporary. The next appearance must retry it.
                    self?.finish(nil, key: key, id: id, record: false)
                    return nil
                }
            }
            running[key] = Make(id: id, task: task, waiters: 1)
            return (id, task)
        }
        let seat = Seat()
        return await withTaskCancellationHandler {
            let value = await task.value
            leave(key, id: id, seat: seat, cancelling: false)
            return value
        } onCancel: {
            leave(key, id: id, seat: seat, cancelling: true)
        }
    }

    /// A caller leaves its make (once). The last caller of a make that is cancelled stops it:
    /// nobody shows the result (its tile scrolled away). A make that already ended, or a newer
    /// make of the same key, is never touched.
    private func leave(_ key: String, id: Int, seat: Seat, cancelling: Bool) {
        let stop = lock.withLock { () -> Task<Value?, Never>? in
            guard !seat.left else { return nil }
            seat.left = true
            guard var make = running[key], make.id == id else { return nil }
            make.waiters -= 1
            guard make.waiters <= 0 else {
                running[key] = make
                return nil
            }
            // Out of the table at once: a tile asking from now on starts a new make.
            running[key] = nil
            return cancelling ? make.task : nil
        }
        stop?.cancel()
    }

    private func finish(_ value: Value?, key: String, id: Int, record: Bool) {
        lock.withLock {
            // A previous, cancelled make may finish after a new one starts:
            // it must never replace the newer entry in the shared cache.
            guard running[key]?.id == id else { return }
            if record { cache.setObject(Entry(value), forKey: key as NSString, cost: cost(value)) }
            running[key] = nil
        }
    }

    /// Callers waiting on the make for `artifact` (tests).
    func waiting(for artifact: TerminalArtifact) -> Int { lock.withLock { running[Self.key(artifact) as String]?.waiters ?? 0 } }
}
