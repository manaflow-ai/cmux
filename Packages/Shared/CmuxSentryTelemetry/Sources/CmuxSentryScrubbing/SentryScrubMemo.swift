import Foundation
#if canImport(os)
import os
#else
import Synchronization
#endif

/// A bounded map from a string to its ``SentryScrubber/scrub(_:)`` result,
/// shared by every copy of one scrubber (Sentry calls `beforeSend` and
/// `beforeBreadcrumb` from any thread).
///
/// Holds at most ``defaultCapacity`` entries (or the capacity given) and only
/// strings up to ``maximumLength`` UTF-8 bytes; when full it starts over, so
/// its memory stays bounded and a later scrub recomputes. The raw strings it
/// keeps are ones already in this process; nothing here leaves it.
public final class SentryScrubMemo: Sendable {
    /// Enough for one event's distinct strings (frames' image paths, debug
    /// images, ~100 breadcrumbs, device context) several times over.
    public static let defaultCapacity = 2_048
    /// Longer strings are scrubbed every time (rare, and big to hold).
    public static let maximumLength = 4_096

    private let capacity: Int
    // `OSAllocatedUnfairLock` (macOS 13 / iOS 16) keeps the type checked
    // `Sendable`; `Synchronization.Mutex` needs macOS 15 / iOS 18.
    // Keyed by exact UTF-8 bytes, not `String` equality: Swift compares strings by
    // canonical equivalence ("caf\u{E9}" == "cafe\u{301}"), but the scrub regexes
    // match literal scalars, so two equal strings can scrub differently.
    let entries = OSAllocatedUnfairLock<[SentryScrubMemoKey: String]>(initialState: [:])

    /// - Parameter capacity: The most entries kept; 0 or less keeps none.
    public init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    /// The remembered result for `text`, if any.
    func result(for text: String) -> String? {
        guard fits(text) else { return nil }
        let key = SentryScrubMemoKey(text)
        return entries.withLock { $0[key] }
    }

    /// Remembers `result` as the scrub of `text`.
    func remember(_ result: String, for text: String) {
        guard fits(text) else { return }
        let capacity = capacity
        let key = SentryScrubMemoKey(text)
        entries.withLock { entries in
            if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
            entries[key] = result
        }
    }

    private func fits(_ text: String) -> Bool {
        capacity > 0 && text.utf8.count <= Self.maximumLength
    }
}

/// A memo key equal only to the same UTF-8 bytes (see ``SentryScrubMemo``).
struct SentryScrubMemoKey: Hashable, Sendable {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }

    func hash(into hasher: inout Hasher) {
        for byte in text.utf8 { hasher.combine(byte) }
    }
}

#if !canImport(os)
/// Linux has no `os` module: the same lock surface over a `Mutex`, so the memo
/// stays checked `Sendable` there too (the Linux package lane builds this target).
final class OSAllocatedUnfairLock<State: Sendable>: Sendable {
    private let mutex: Mutex<State>

    init(initialState: State) {
        mutex = Mutex(initialState)
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try mutex.withLock { try body(&$0) }
    }
}
#endif
