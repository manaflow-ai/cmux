import Foundation

/// Selection + fallback logic for the iOS "View as Text" capture, split
/// out of `GhosttySurfaceRegistry` so the two decisions that actually decide
/// whether the sheet shows text or its empty state are host-testable without
/// libghostty, UIKit, or a live surface.
///
/// Two things were silently making the sheet show "No terminal text available"
/// even with visible output:
///
/// 1. The candidate predicate is id-scoped AND visibility-scoped. If the chosen
///    surface is re-resolved from the registry *after* the sheet has begun
///    presenting, a transient `window == nil` / `isHidden` / `alpha` drop on the
///    presenter can exclude the one live surface, yielding nil. Callers now arm
///    the capture before sheet presentation, so visibility is only a preference;
///    terminal id, live surface pointer, and non-dismantled state remain the
///    safety invariants that prevent stale or cross-terminal reads.
/// 2. `surfaceText` returns a non-nil empty string when the range has zero bytes,
///    so `screen ?? viewport` never fell back when SCREEN read empty-but-ok. The
///    `resolvedText` decision below treats nil OR empty SCREEN as "try VIEWPORT".
public struct CopyableTerminalTextSelection: Sendable {
    /// Creates a selection helper.
    public init() {}

    /// Whether `candidate` may back the "View as Text" capture for `surfaceID`.
    ///
    /// The id scoping keeps a second surface (another iPad scene, an in-flight
    /// transition) from leaking a different workspace's terminal into the
    /// capture; `hasSurface && !isDismantled` keeps freed or SwiftUI-removed
    /// surfaces out. Window/hidden/alpha are intentionally ignored because
    /// UIKit can transiently flip them while the menu action presents the
    /// sheet, before the queued surface read runs.
    public func isEligible(_ candidate: CopyableTerminalTextCandidate, for surfaceID: String) -> Bool {
        candidate.hostSurfaceID == surfaceID
            && candidate.hasSurface
            && !candidate.isDismantled
    }

    /// Whether `candidate` is visibly mounted. This is a preference, not an
    /// eligibility requirement, because UIKit can transiently flip these bits
    /// during menu presentation.
    public func isVisible(_ candidate: CopyableTerminalTextCandidate) -> Bool {
        candidate.hasWindow
            && !candidate.isHidden
            && candidate.alpha > 0.01
    }

    /// The deterministic pick from the registered candidates: a visible
    /// eligible match when possible, otherwise the lowest-keyed eligible match.
    /// `candidates` must be supplied lowest-key-first.
    ///
    /// - Returns: The index of the chosen candidate in `candidates`, or nil when
    ///   none is eligible.
    public func chosenIndex(
        from candidates: [CopyableTerminalTextCandidate],
        for surfaceID: String
    ) -> Int? {
        let eligibleIndices = candidates.indices.filter { isEligible(candidates[$0], for: surfaceID) }
        return eligibleIndices.first { isVisible(candidates[$0]) } ?? eligibleIndices.first
    }

    /// The text the sheet should show given the SCREEN and VIEWPORT reads.
    ///
    /// `surfaceText` returns nil on a failed read and a non-nil empty string for
    /// a zero-byte range, so a plain `screen ?? viewport` never fell back when
    /// SCREEN read empty-but-ok. Here a SCREEN result that is nil OR empty falls
    /// through to VIEWPORT, and only a VIEWPORT result that is also nil/empty
    /// yields nil (the honest empty state).
    ///
    /// - Parameters:
    ///   - screen: The SCREEN (scrollback + all rows) read, nil on failure.
    ///   - viewport: The VIEWPORT (visible rows) read, nil on failure.
    /// - Returns: The non-empty text to show, or nil when neither has content.
    public func resolvedText(screen: String?, viewport: String?) -> String? {
        if let screen, !screen.isEmpty { return screen }
        if let viewport, !viewport.isEmpty { return viewport }
        return nil
    }
}
