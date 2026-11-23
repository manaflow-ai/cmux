public import CmuxNextDesign
import Foundation

/// How a workspace row shows an agent that drives the screen (Computer Use) or a browser
/// (Debug Settings `sidebar.driveIndicator`, Lawrence 2026-11-07: "the computer use/browser use
/// indicator in workspaces needs to be better"). Every look names the agent and what it drives in
/// its tooltip and accessibility label, and a click opens Go to and Stop.
public nonisolated enum SidebarDriveIndicatorVariant: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// A tinted capsule: what it drives as a glyph, then the agent's short name, in the agent's color (the default).
    case capsule
    /// The glyph alone, in the agent's color.
    case glyph
    /// The glyph knocked out of a solid disc of the agent's color.
    case badge
    /// The presence dot (cx-gg84), the look before this redesign.
    case dot

    public var tunableTitle: String {
        switch self {
        case .capsule: "Capsule with agent name"
        case .glyph: "Glyph"
        case .badge: "Solid badge"
        case .dot: "Dot (before)"
        }
    }
}
