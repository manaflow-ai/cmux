import Foundation

/// Pure selection + fallback logic for the iOS "View as Text" capture, split
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
///    presenter can exclude the one live surface, yielding nil. The fix moves the
///    resolve to tap time (see `GhosttySurfaceRegistry`), but the predicate is
///    still the single source of truth and is unit-tested here.
/// 2. `surfaceText` returns a non-nil empty string when the range has zero bytes,
///    so `screen ?? viewport` never fell back when SCREEN read empty-but-ok. The
///    `resolvedText` decision below treats nil OR empty SCREEN as "try VIEWPORT".
public enum CopyableTerminalTextSelection {
    /// Inputs describing a registered surface view for the eligibility decision.
    /// Mirrors the runtime fields read off `GhosttySurfaceView` (`hostSurfaceID`,
    /// `surface != nil`, `window != nil`, `isHidden`, `alpha`) as plain values so
    /// the rule is testable without a UIKit view.
    public struct Candidate: Equatable, Sendable {
        public let hostSurfaceID: String?
        public let hasSurface: Bool
        public let hasWindow: Bool
        public let isHidden: Bool
        public let alpha: Double

        public init(
            hostSurfaceID: String?,
            hasSurface: Bool,
            hasWindow: Bool,
            isHidden: Bool,
            alpha: Double
        ) {
            self.hostSurfaceID = hostSurfaceID
            self.hasSurface = hasSurface
            self.hasWindow = hasWindow
            self.isHidden = isHidden
            self.alpha = alpha
        }
    }

    /// Whether `candidate` is the live, on-screen surface for `surfaceID` and so
    /// may back the "View as Text" capture.
    ///
    /// The id scoping keeps a second visible surface (another iPad scene, an
    /// in-flight transition) from leaking a different workspace's terminal into
    /// the capture; `hasSurface` keeps a dismantling view (registry-resident with
    /// a non-nil pointer until its queued dispose runs) from contributing stale
    /// text; the window/hidden/alpha gates keep an off-screen surface out.
    public static func isEligible(_ candidate: Candidate, for surfaceID: String) -> Bool {
        candidate.hostSurfaceID == surfaceID
            && candidate.hasSurface
            && candidate.hasWindow
            && !candidate.isHidden
            && candidate.alpha > 0.01
    }

    /// The deterministic pick from the registered candidates: the lowest-keyed
    /// eligible match. When the same terminal is mounted in several scenes the
    /// contents are identical, so the lowest-keyed visible match keeps the pick
    /// stable. `candidates` must be supplied lowest-key-first.
    ///
    /// - Returns: The index of the chosen candidate in `candidates`, or nil when
    ///   none is eligible.
    public static func chosenIndex(
        from candidates: [Candidate],
        for surfaceID: String
    ) -> Int? {
        candidates.firstIndex { isEligible($0, for: surfaceID) }
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
    public static func resolvedText(screen: String?, viewport: String?) -> String? {
        if let screen, !screen.isEmpty { return screen }
        if let viewport, !viewport.isEmpty { return viewport }
        return nil
    }
}
