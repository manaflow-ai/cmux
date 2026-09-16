/// Owns the boundary between live pane geometry and committed renderer sizes.
///
/// A host keeps publication deferred until it has installed final pane geometry:
/// ```swift
/// var phase = TerminalPortalResizePhase()
/// phase.begin()
/// phase.requestEnd()
/// // Install final pane frames before releasing renderer publication.
/// phase.commitEnd(nativeResizeActive: false)
/// ```
public struct TerminalPortalResizePhase: Sendable {
    private enum Phase: Equatable, Sendable {
        case idle
        case resizing
        case ending
        case completedAwaitingNativeEnd
    }

    private var phase = Phase.idle

    /// Creates an idle resize phase.
    public init() {}

    /// Whether renderer and PTY size publication must wait for final geometry.
    public var defersRenderer: Bool {
        phase == .resizing || phase == .ending
    }

    /// Whether a resize-end event is waiting for the final geometry pass.
    public var isEnding: Bool { phase == .ending }

    /// Starts a new resize, superseding callbacks from an earlier transaction.
    public mutating func begin() {
        phase = .resizing
    }

    /// Keeps publication deferred until the final geometry pass commits.
    public mutating func requestEnd() {
        phase = .ending
    }

    /// Ignores callbacks from a completed resize until AppKit clears its signal
    /// or an explicit start establishes a new resize transaction.
    ///
    /// - Parameter active: The current native live-resize signal.
    /// - Returns: Whether the caller should reconcile geometry for this event.
    public mutating func observeNativeResize(active: Bool) -> Bool {
        switch (phase, active) {
        case (.completedAwaitingNativeEnd, true):
            return false
        case (.completedAwaitingNativeEnd, false):
            phase = .idle
        case (.idle, true):
            phase = .resizing
        default:
            break
        }
        return true
    }

    /// Releases publication only after the portal installs final pane geometry.
    ///
    /// - Parameter nativeResizeActive: Whether native callbacks still belong to the ended resize.
    public mutating func commitEnd(nativeResizeActive: Bool) {
        phase = nativeResizeActive ? .completedAwaitingNativeEnd : .idle
    }

    /// Returns the phase to idle when its portal is retired.
    public mutating func reset() {
        phase = .idle
    }
}
