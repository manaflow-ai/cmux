/// Decides when a "Jump to Bottom" affordance shows for a scrolling view whose
/// newest content arrives at the bottom (a terminal's scrollback, an agent
/// chat transcript).
///
/// The type knows nothing about the view it serves. A host reports where the
/// viewport is with ``Snapshot`` on every scroll or content change and draws
/// ``isVisible`` and ``hasNewContentBelow``.
public struct JumpToBottomAffordance: Equatable, Sendable {
    /// Where the viewport is, in the host's own units (terminal rows, chat
    /// messages). Only differences between snapshots matter.
    public struct Snapshot: Equatable, Sendable {
        /// Units between the viewport's bottom edge and the newest content.
        /// Zero means the viewport is at the bottom.
        public var distanceFromBottom: UInt64

        /// Total content length. Growth while the viewport is off the bottom
        /// counts as new content below it.
        public var contentLength: UInt64

        /// Changes when the host re-lays out its content (a terminal reflowing
        /// to a new width), so length changes it causes are not mistaken for
        /// new content.
        public var layoutKey: Int

        public init(distanceFromBottom: UInt64, contentLength: UInt64, layoutKey: Int = 0) {
            self.distanceFromBottom = distanceFromBottom
            self.contentLength = contentLength
            self.layoutKey = layoutKey
        }
    }

    /// Whether the affordance is shown.
    public private(set) var isVisible = false

    /// Whether content arrived below the viewport since it left the bottom.
    public private(set) var hasNewContentBelow = false

    /// Set while the content owner draws its own scrolling (a full-screen
    /// terminal program on the alternate screen), so the owner check is not
    /// repeated for every snapshot until the viewport returns to the bottom.
    private var isSuppressedByContentOwner = false
    /// Content length and layout when the viewport left the bottom.
    private var baseline: Baseline?

    private struct Baseline: Equatable, Sendable {
        var contentLength: UInt64
        var layoutKey: Int
    }

    public init() {}

    /// Applies the viewport's latest position.
    ///
    /// - Parameters:
    ///   - snapshot: The viewport position, or `nil` when the host has no
    ///     content geometry yet.
    ///   - isEnabled: Whether the user allows the affordance.
    ///   - contentOwnsScrolling: Whether the content draws its own scrolling
    ///     and jump control. Evaluated only when the affordance would appear,
    ///     so a host may back it with an expensive read.
    /// - Returns: `true` when ``isVisible`` or ``hasNewContentBelow`` changed.
    @discardableResult
    public mutating func update(
        _ snapshot: Snapshot?,
        isEnabled: Bool,
        contentOwnsScrolling: () -> Bool
    ) -> Bool {
        let wasVisible = isVisible
        let hadNewContent = hasNewContentBelow
        apply(snapshot, isEnabled: isEnabled, contentOwnsScrolling: contentOwnsScrolling)
        return wasVisible != isVisible || hadNewContent != hasNewContentBelow
    }

    private mutating func apply(
        _ snapshot: Snapshot?,
        isEnabled: Bool,
        contentOwnsScrolling: () -> Bool
    ) {
        guard let snapshot, snapshot.distanceFromBottom > 0 else {
            reset()
            return
        }
        guard isEnabled else {
            // Keep the owner decision so re-enabling mid-review does not
            // resurface a pill over a program that draws its own.
            isVisible = false
            hasNewContentBelow = false
            baseline = nil
            return
        }
        if isSuppressedByContentOwner { return }
        if !isVisible {
            guard !contentOwnsScrolling() else {
                isSuppressedByContentOwner = true
                return
            }
            isVisible = true
        }
        guard let baseline, baseline.layoutKey == snapshot.layoutKey else {
            self.baseline = Baseline(contentLength: snapshot.contentLength, layoutKey: snapshot.layoutKey)
            return
        }
        if snapshot.contentLength > baseline.contentLength {
            hasNewContentBelow = true
        }
        // Content may shrink (scrollback trimmed); later growth is measured
        // from the smaller length.
        self.baseline?.contentLength = min(baseline.contentLength, snapshot.contentLength)
    }

    /// Hides the affordance and forgets its history, for example when the
    /// host starts showing different content.
    public mutating func reset() {
        isVisible = false
        hasNewContentBelow = false
        isSuppressedByContentOwner = false
        baseline = nil
    }
}
