import Foundation

/// The scrollback-budget policy for the Mac's mobile terminal data plane.
///
/// Live render-grid events carry no scrollback: the phone keeps its own bounded
/// Ghostty scrollback mirror and scrolls that mirror locally while the Mac
/// remains authoritative. This policy fixes the two scrollback windows the Mac
/// is willing to materialize and clamps an attacker- or client-supplied request
/// to the larger of them.
///
/// - ``replayScrollbackLineBudget`` is the row count included in a cold-attach
///   render-grid replay snapshot.
/// - ``prefetchScrollbackLineBudget`` is the larger history window returned only
///   on an explicit mobile scroll-prefetch request, keeping ordinary scroll RPCs
///   small.
///
/// ``rowsToPrefetch(requestedRows:)`` is a pure clamp: a request is floored at
/// zero (a negative or absent count yields zero, suppressing the render-grid
/// section of the response) and capped at ``prefetchScrollbackLineBudget``.
public struct MobileScrollPrefetchPolicy: Equatable, Hashable, Sendable {
    /// Scrollback rows included in a cold-attach render-grid replay snapshot.
    public var replayScrollbackLineBudget: Int

    /// Larger history window returned only on explicit mobile scroll prefetch
    /// requests, keeping ordinary scroll RPCs small.
    public var prefetchScrollbackLineBudget: Int

    /// Creates a scroll-prefetch policy from explicit scrollback budgets. The
    /// defaults are the standard policy: a 240-row cold-attach replay window
    /// and a 600-row explicit-prefetch cap.
    ///
    /// - Parameters:
    ///   - replayScrollbackLineBudget: Rows included in a cold-attach replay.
    ///   - prefetchScrollbackLineBudget: Cap for an explicit prefetch request.
    public init(replayScrollbackLineBudget: Int = 240, prefetchScrollbackLineBudget: Int = 600) {
        self.replayScrollbackLineBudget = replayScrollbackLineBudget
        self.prefetchScrollbackLineBudget = prefetchScrollbackLineBudget
    }

    /// Clamps a client-requested prefetch row count to the allowed window.
    ///
    /// A negative or zero request yields zero (the caller then omits the
    /// render-grid section); any positive request is capped at
    /// ``prefetchScrollbackLineBudget``.
    ///
    /// - Parameter requestedRows: The raw row count the client asked for.
    /// - Returns: The number of scrollback rows the Mac will materialize.
    public func rowsToPrefetch(requestedRows: Int) -> Int {
        min(max(0, requestedRows), prefetchScrollbackLineBudget)
    }
}
