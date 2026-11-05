public import CmuxNextDesignTokens

/// Sidebar Thunderdome E, "chaos mode" (Leo 2026-11-05: "we can get artsy ... we can get extravagant, we can
/// get maximalist"): four maximalist treatments of the corner where the vertical sidebar meets the
/// horizontal tab strip at the main pane's top-leading corner. A Debug Settings choice, off by default;
/// every variant draws in `CornerChaosView` over the gutter and changes no frame, layout or existing
/// component. Ultra-compact keeps its look under every value (Lawrence likes it as it is).
public nonisolated enum CornerChaosStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The shipped corner: nothing drawn.
    case off
    /// A liquid bridge: the selected workspace's fill flows across the gutter into the main pane with
    /// concave (metaball) fillets, and glides to the next row when the selection moves.
    case liquid
    /// One lit line: a single path that runs up the sidebar's edge, turns the corner and runs along
    /// the tab strip, brightest at the tangent point, with a node at the selected workspace.
    case circuit
    /// A chamfered HUD bracket (game UI, Teenage Engineering): a 45° cut around the corner with
    /// measured ticks, and a chamfered pointer at the selected workspace.
    case bracket
    /// The corner as a live element: a crisp round seal on the tangent point, in the selected
    /// workspace's color with its initial, that pops when the workspace changes.
    case seal

    public var tunableTitle: String {
        switch self {
        case .off: "Off (shipped corner)"
        case .liquid: "Liquid bridge (selected row flows into the pane)"
        case .circuit: "Circuit (one lit line, sidebar to tab strip)"
        case .bracket: "Bracket (chamfered HUD corner)"
        case .seal: "Seal (live workspace badge on the corner)"
        }
    }

    public static let tunable = Tunable<CornerChaosStyle>.choice(
        "chrome.cornerChaos", .sidebar, "Corner chaos (Thunderdome E)",
        help: "Maximalist treatments of the corner where the sidebar meets the tab strip: a liquid bridge from the selected workspace into the pane, one lit line along both edges, a chamfered HUD bracket, or a live workspace seal on the corner. Ultra-compact keeps the shipped corner.",
        default: .off, code: "CornerChaosStyle.tunable")
}
