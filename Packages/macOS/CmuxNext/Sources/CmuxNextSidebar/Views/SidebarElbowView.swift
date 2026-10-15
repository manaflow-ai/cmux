import AppKit
import CmuxNextDesign

/// Group by Status's elbow (`SidebarGrouping.elbowsChildren`, Labs): the CLI connector `⎿` a child
/// agent session's row draws at its leading edge, in tertiary ink, so the row reads as hanging off
/// the parent row above it, as a tool result hangs off its call in Claude Code's output.
final class SidebarElbowView: NSView {
    static let glyph = "⎿"
}
