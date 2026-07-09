public import Foundation

/// Decides whether an open-or-focus surface request reuses an existing surface
/// or creates a new one.
///
/// This is the package-pure core of the workspace's five `openOrFocus…` entry
/// points (markdown split/tab, file-preview split/tab, right-sidebar tool tab).
/// Each entry point scanned its panel registry for the first surface of the
/// right kind whose identity matched the request, focused it if appropriate,
/// and otherwise created a new surface. That scan-and-route decision is the
/// same across all five and carries no live AppKit state, so it lives here as a
/// value-in / value-out resolver the app target drives.
///
/// The resolver is generic over an opaque identity `Key` (the resolved file
/// path, or the right-sidebar mode) so it never imports the app target's
/// `Panel` or `RightSidebarMode` types. The caller builds the candidate list in
/// the workspace registry's iteration order; the resolver returns the first
/// match exactly as the legacy `for (existingId, panel) in panels` loop did.
public struct SurfaceReuseResolver: Sendable {
    /// Creates a resolver.
    public init() {}

    /// Returns the reuse decision for a request matching `requestedKey` against
    /// `candidates`, taken in the caller's iteration order.
    ///
    /// - Parameters:
    ///   - candidates: existing surfaces of the requested kind, each carrying
    ///     its identity key, in registry-iteration order.
    ///   - requestedKey: the identity of the content being opened.
    ///   - shouldFocusExisting: whether a matched existing surface should be
    ///     focused. The split entry points pass `true` unconditionally; the
    ///     in-pane entry points pass their own `focus` flag.
    /// - Returns: `.focusExisting` for the first candidate whose key equals
    ///   `requestedKey`, otherwise `.create`.
    public func decision<Key: Hashable & Sendable>(
        candidates: [SurfaceReuseCandidate<Key>],
        requestedKey: Key,
        shouldFocusExisting: Bool
    ) -> SurfaceReuseDecision {
        for candidate in candidates where candidate.key == requestedKey {
            return .focusExisting(panelId: candidate.panelId, shouldFocus: shouldFocusExisting)
        }
        return .create
    }
}
