public import CoreGraphics

/// Where an agent cursor for a target tab draws (decisions CURSOR-HIDDEN,
/// CURSOR-SHOW, CURSOR-SCREENS, 2026-10-04). Rects are in the overlay
/// coordinates of `window`.
public nonisolated enum AgentCursorVisibility: Equatable, Sendable {
    /// The target's page is on screen. `viewport` is the page viewport the
    /// event coordinates map into; `clip` is its part not scrolled out or
    /// under a docked column (equal to `viewport` when fully shown).
    case visible(window: String, viewport: CGRect, clip: CGRect, zoom: Double)
    /// The target is in `window` but not shown: an indicator in the session
    /// color pulses at `rect`. Never over a pane that is not the target.
    case hidden(window: String, anchor: AgentCursorAnchor, rect: CGRect)
    /// Nothing draws.
    case notDrawn(AgentCursorNotDrawnReason)
}

public nonisolated enum AgentCursorNotDrawnReason: String, Codable, Equatable, Sendable {
    /// No tab has the target id.
    case tabClosed
    /// No window shows or lists the tab's workspace.
    case notInAnyWindow
    case minimized
    /// The window is on another Space.
    case otherSpace
}
