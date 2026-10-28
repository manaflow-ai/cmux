import Foundation

/// Values made once per artifact this session (grid thumbnails), by artifact id and kind, so an
/// artifact that moves in the list or is referenced again keeps its value. An edit is new content:
/// an "Edited" detail is part of the key, so a file the agent changed again gets a new thumbnail. An `NSCache`, so memory
/// pressure evicts entries. A make that was cancelled (the tile scrolled away) is not recorded,
/// not even as a failure: the next ask makes it again.
final class ArtifactMemo<Value>: @unchecked Sendable {
    private final class Entry {
        let value: Value?
        init(_ value: Value?) { self.value = value }
    }

    private let cache = NSCache<NSString, Entry>()
    private let cost: (Value?) -> Int
    private let lock = NSLock()
    private var makes = 0

    init(costLimit: Int, cost: @escaping (Value?) -> Int = { _ in 1 }) {
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

    func value(for artifact: TerminalArtifact, make: (TerminalArtifact) async -> Value?) async -> Value? {
        if let cached = cached(artifact) { return cached }
        lock.withLock { makes += 1 }
        let value = await make(artifact)
        // Cancelled (scrolled away): keep nothing, so the tile tries again when it returns.
        guard !Task.isCancelled else { return value }
        cache.setObject(Entry(value), forKey: Self.key(artifact), cost: cost(value))
        return value
    }
}
