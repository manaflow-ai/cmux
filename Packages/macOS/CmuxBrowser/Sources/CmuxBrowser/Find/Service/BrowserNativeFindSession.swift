import Foundation

/// Find-in-page backed by an engine's native find (Chromium), with the same surface as the
/// script-driven ``BrowserFindService``.
///
/// The engine answers each request with a stream of find-result events; only the final event
/// answers the caller. A new request, ``clear()`` or ``cancelPending()`` answers a pending
/// request with `nil` (the find bar keeps its count, as when a WebKit find script fails), so a
/// caller never waits forever, for example when the page navigates away mid-search.
///
/// ```swift
/// let session = BrowserNativeFindSession(driver: chromiumFindDriver)
/// let count = await session.search(needle: "cmux")   // {total: 4, selected: 0}
/// // Engine event: session.receiveResult(count: 4, activeOrdinal: 1, isFinal: true)
/// ```
@MainActor
public final class BrowserNativeFindSession: BrowserFinding {
    private let driver: any BrowserNativeFindDriving
    private let matchCase: Bool
    private var needle = ""
    /// The page committed a new document since the last request: the next request starts a
    /// fresh search instead of stepping from a match the old document had.
    private var documentChanged = false
    private var pending: CheckedContinuation<BrowserFindMatchCount?, Never>?

    /// Creates a session over an engine's native find.
    /// - Parameters:
    ///   - driver: The engine that runs the searches.
    ///   - matchCase: Whether searches are case-sensitive. Defaults to `false`, matching the
    ///     WebKit find scripts and Chrome's find bar.
    public init(driver: any BrowserNativeFindDriving, matchCase: Bool = false) {
        self.driver = driver
        self.matchCase = matchCase
    }

    /// The needle of the current search; empty when nothing is being searched.
    public var currentNeedle: String { needle }

    /// Whether a request is waiting for the engine's final result.
    public var hasPendingRequest: Bool { pending != nil }

    /// Searches for `needle`. The same needle as the current search steps to the next match,
    /// like typing Return in Chrome's find bar.
    public func search(needle: String) async -> BrowserFindMatchCount? {
        guard !needle.isEmpty else { return nil }
        let isNewNeedle = needle != self.needle || documentChanged
        self.needle = needle
        return await request(forward: true, findNext: !isNewNeedle)
    }

    public func next() async -> BrowserFindMatchCount? {
        guard !needle.isEmpty else { return nil }
        return await request(forward: true, findNext: !documentChanged)
    }

    public func previous() async -> BrowserFindMatchCount? {
        guard !needle.isEmpty else { return nil }
        return await request(forward: false, findNext: !documentChanged)
    }

    public func clear() async {
        cancelPending()
        needle = ""
        documentChanged = false
        // Chrome keeps the active match selected when its find bar closes.
        driver.stopFinding(clearSelection: false)
    }

    /// Forwards one find-result event from the engine.
    ///
    /// Only the final event of a request answers the caller; earlier events (Chromium reports
    /// counts while it scans the page) are ignored.
    /// - Parameters:
    ///   - count: The number of matches found so far.
    ///   - activeOrdinal: The 1-based ordinal of the active match, or `0` when none is active.
    ///   - isFinal: Whether this is the request's last event.
    public func receiveResult(count: Int, activeOrdinal: Int, isFinal: Bool) {
        guard isFinal, let continuation = pending else { return }
        pending = nil
        continuation.resume(returning: Self.matchCount(count: count, activeOrdinal: activeOrdinal))
    }

    /// Answers a pending request with `nil` (superseded, page navigated, engine closed).
    public func cancelPending() {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(returning: nil)
    }

    /// The page committed a new document: the next request (``search(needle:)``, ``next()``,
    /// ``previous()``) starts a fresh search for the same needle instead of stepping a stale
    /// one. The needle stays, so the find bar's Return and Cmd-G keep working across a
    /// navigation, as they do for a WebKit page.
    public func resetForNewDocument() {
        cancelPending()
        documentChanged = true
    }

    /// Maps Chromium's result to the find bar's count: a 1-based active ordinal becomes the
    /// 0-based selected index ``BrowserFindMatchCount`` uses.
    /// - Parameters:
    ///   - count: The number of matches; zero or negative means none.
    ///   - activeOrdinal: The 1-based active match ordinal; out-of-range values clamp.
    /// - Returns: The validated match count.
    nonisolated static func matchCount(count: Int, activeOrdinal: Int) -> BrowserFindMatchCount {
        guard count > 0 else { return BrowserFindMatchCount(total: 0, selected: nil) }
        let ordinal = min(max(activeOrdinal, 1), count)
        return BrowserFindMatchCount(total: UInt(count), selected: UInt(ordinal - 1))
    }

    private func request(forward: Bool, findNext: Bool) async -> BrowserFindMatchCount? {
        cancelPending()
        let needle = self.needle
        documentChanged = false
        return await withCheckedContinuation { continuation in
            pending = continuation
            guard driver.find(needle, forward: forward, matchCase: matchCase, findNext: findNext) else {
                // No result event follows; answer now so the find bar keeps its count.
                pending = nil
                continuation.resume(returning: nil)
                return
            }
        }
    }
}
