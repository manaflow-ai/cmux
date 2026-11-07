/// Selects whether shared-terminal bounds stay visible outside a sizing gesture.
public enum TerminalSizingOverlayPresentation: Hashable, Sendable {
    /// Show bounds only while the pane is being sized intentionally.
    case interactiveOnly
    /// Keep the remote sizing projection visible while the view is attached.
    case persistent
}

/// Owns the lifetime and authority of one terminal sizing overlay.
///
/// The AppKit view supplies committed layout revisions and forwards focus,
/// visibility, and resize-session events. Older snapshots and geometry
/// observations are rejected before they can affect drawing.
public struct TerminalSizingOverlayLifecycle: Sendable {
    /// The snapshot currently owned by this pane.
    public private(set) var snapshot: TerminalSharingSnapshot?
    /// The latest geometry accepted for the current layout authority.
    public private(set) var geometry: TerminalSizeBoundsGeometry?
    /// Whether the overlay has anything it is allowed to present.
    public private(set) var isVisible = false
    /// Whether an intentional pane/workspace sizing gesture is active.
    public private(set) var isInteractionActive = false
    /// Whether the pane still has focus in its window and workspace.
    public private(set) var isFocused = true
    /// Whether the pane is currently presented by its portal host.
    public private(set) var isSurfaceVisible = true

    private var presentation: TerminalSizingOverlayPresentation
    private var acceptedGeometryRevision: UInt64?
    private var acceptedGeometrySnapshotGeneration: UInt64?
    private var hiddenAfterFocusLoss = false

    /// Creates a lifecycle with the local, transient presentation policy.
    public init(presentation: TerminalSizingOverlayPresentation = .interactiveOnly) {
        self.presentation = presentation
    }

    /// Applies a snapshot if it belongs to the current surface generation.
    ///
    /// - Parameters:
    ///   - snapshot: the new host or relay snapshot, or `nil` to clear it.
    ///   - presentation: the presentation policy for this ownership path.
    /// - Returns: Whether the visible lifecycle state changed or the snapshot
    ///   was accepted.
    @discardableResult
    public mutating func update(
        snapshot next: TerminalSharingSnapshot?,
        presentation nextPresentation: TerminalSizingOverlayPresentation? = nil
    ) -> Bool {
        let previousSnapshot = snapshot
        if let current = previousSnapshot, let next {
            guard next.state.generation >= current.state.generation else { return false }
            // A generation identifies one complete state. Equal-generation
            // replacements may update view metadata (for example, detach)
            // but may not replace the state with a competing observation.
            guard next.state.generation != current.state.generation || next.state == current.state else {
                return false
            }
        }

        let changed = previousSnapshot != next || nextPresentation.map { $0 != presentation } == true
        let stateRevisionAdvanced = next.map { candidate in
            previousSnapshot.map { candidate.state.generation > $0.state.generation } ?? true
        } ?? false
        snapshot = next
        if let nextPresentation { presentation = nextPresentation }
        if next == nil {
            clearGeometry()
            isInteractionActive = false
            hiddenAfterFocusLoss = false
        } else if changed {
            // A new snapshot invalidates the old geometry; the current layout
            // must publish a newer observation before bounds can draw again.
            clearGeometry()
            if stateRevisionAdvanced, isFocused, isSurfaceVisible {
                hiddenAfterFocusLoss = false
            }
        }
        return changed || recomputeVisibility()
    }

    /// Records the start of an intentional pane or workspace sizing gesture.
    @discardableResult
    public mutating func beginInteraction() -> Bool {
        guard snapshot != nil, isFocused, isSurfaceVisible else { return false }
        hiddenAfterFocusLoss = false
        isInteractionActive = true
        return recomputeVisibility()
    }

    /// Ends a sizing gesture and clears transient bounds immediately.
    @discardableResult
    public mutating func endInteraction() -> Bool {
        isInteractionActive = false
        if presentation == .interactiveOnly { clearGeometry() }
        return recomputeVisibility()
    }

    /// Cancels a sizing gesture, including cancellation caused by focus loss.
    @discardableResult
    public mutating func cancelInteraction() -> Bool {
        endInteraction()
    }

    /// Clears the presentation when the pane or window loses focus.
    @discardableResult
    public mutating func focusLost() -> Bool {
        isFocused = false
        isInteractionActive = false
        if presentation == .interactiveOnly { clearGeometry() }
        hiddenAfterFocusLoss = true
        return recomputeVisibility()
    }

    /// Records focus returning to the pane. A new gesture or snapshot is still
    /// required before a transient overlay can reappear.
    @discardableResult
    public mutating func focusGained() -> Bool {
        isFocused = true
        if presentation == .persistent { hiddenAfterFocusLoss = false }
        return recomputeVisibility()
    }

    /// Clears transient bounds when a tab/workspace portal hides this pane.
    @discardableResult
    public mutating func surfaceVisibilityChanged(_ visible: Bool) -> Bool {
        isSurfaceVisible = visible
        if !visible {
            isInteractionActive = false
            if presentation == .interactiveOnly { clearGeometry() }
            hiddenAfterFocusLoss = true
        } else if presentation == .persistent {
            hiddenAfterFocusLoss = false
        }
        return recomputeVisibility()
    }

    /// Accepts geometry only from the current monotonically increasing layout
    /// authority. Local bounds accept observations only during an interaction;
    /// a late observation from an older commit cannot redraw them.
    /// Returns `true` only when this observation was accepted.
    @discardableResult
    public mutating func updateGeometry(
        _ next: TerminalSizeBoundsGeometry,
        revision: UInt64,
        snapshotGeneration: UInt64? = nil
    ) -> Bool {
        guard let snapshot else { return false }
        if let snapshotGeneration {
            guard snapshot.state.generation == snapshotGeneration else { return false }
        }
        let generation = snapshotGeneration ?? snapshot.state.generation
        if let acceptedGeneration = acceptedGeometrySnapshotGeneration {
            guard generation >= acceptedGeneration else { return false }
        }
        guard presentation == .persistent || isInteractionActive else { return false }
        if let acceptedGeometryRevision {
            guard revision > acceptedGeometryRevision else {
                return false
            }
        }
        acceptedGeometrySnapshotGeneration = generation
        acceptedGeometryRevision = revision
        geometry = next
        _ = recomputeVisibility()
        return true
    }

    /// Whether the current geometry should draw the border, hatch, and chip.
    public var showsBounds: Bool {
        isSurfaceVisible && isFocused && !hiddenAfterFocusLoss
            && snapshot?.showsBoundsChrome == true
            && geometry?.needsDecoration == true
            && (presentation == .persistent || isInteractionActive)
    }

    @discardableResult
    private mutating func recomputeVisibility() -> Bool {
        let previous = isVisible
        let hasDetachedCard = snapshot?.detachment != nil
        let hasBounds = snapshot?.showsBoundsChrome == true && geometry?.needsDecoration == true
        let policyAllowsBounds = presentation == .persistent || isInteractionActive
        isVisible = isSurfaceVisible && (hasDetachedCard || (
            isFocused && !hiddenAfterFocusLoss && hasBounds && policyAllowsBounds
        ))
        return previous != isVisible
    }

    private mutating func clearGeometry() {
        geometry = nil
        acceptedGeometrySnapshotGeneration = nil
    }
}
