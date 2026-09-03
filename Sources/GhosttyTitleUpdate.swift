import Foundation

/// Sendable title payload captured at the Ghostty callback boundary.
struct GhosttyTitleUpdate: Equatable, Sendable {
    let tabId: UUID
    let surfaceId: UUID
    /// The title exactly as the terminal emitted it, spinner frame included.
    let title: String
    /// `title` with any standalone spinner frame removed. Successive animation
    /// ticks share a `stableTitle`, which is what lets the expensive consumers
    /// tell "the label changed" from "the spinner advanced".
    let stableTitle: String
    let sourceSurfaceIdentifier: ObjectIdentifier
    let terminalLifecycleID: UUID
    let attachmentGeneration: UInt64

    /// True when this update carries a new animation frame and nothing else.
    var isSpinnerFrameOnly: Bool { title != stableTitle }

    init(
        tabId: UUID,
        surfaceId: UUID,
        title: String,
        stableTitle: String? = nil,
        sourceSurfaceIdentifier: ObjectIdentifier,
        terminalLifecycleID: UUID,
        attachmentGeneration: UInt64 = 0
    ) {
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.title = title
        self.stableTitle = stableTitle ?? title
        self.sourceSurfaceIdentifier = sourceSurfaceIdentifier
        self.terminalLifecycleID = terminalLifecycleID
        self.attachmentGeneration = attachmentGeneration
    }
}
