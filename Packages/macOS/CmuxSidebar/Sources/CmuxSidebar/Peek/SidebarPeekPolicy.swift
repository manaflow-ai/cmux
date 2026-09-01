public import Foundation

/// The tunable behaviour of the peek interaction.
///
/// Every value here is a real preference someone will want to change: how
/// eager the reveal is, how forgiving the dismissal is, and whether picking a
/// workspace closes the panel. Keeping them in one value type means the
/// settings surface configures a policy rather than reaching into the machine.
public struct SidebarPeekPolicy: Sendable, Hashable {
    /// How long the pointer must rest in the edge strip before revealing.
    public let dwell: Duration
    /// How long the panel survives after the last hold is released.
    public let grace: Duration
    /// Width of the pointer-sensitive strip along the window's leading edge.
    public let edgeWidth: Double
    /// Whether activating a workspace dismisses the panel.
    ///
    /// On by default: peek is a reach-in gesture, and staying open after the
    /// user has said where they wanted to go leaves the panel covering the
    /// content they just asked for.
    public let dismissesOnWorkspaceActivation: Bool
    /// Whether peek is enabled at all.
    public let isEnabled: Bool

    /// The shipped defaults.
    ///
    /// 180ms of dwell is long enough that crossing the edge on the way
    /// somewhere else does not trigger a reveal, and short enough that a
    /// deliberate rest feels immediate. 250ms of grace covers the diagonal
    /// from the edge strip into the panel and a grazing exit along a row,
    /// while keeping the dismissal feeling immediate once the pointer has
    /// genuinely left. The 10pt strip forgives a pointer thrown at the
    /// screen edge that stops a few points short.
    public static let `default` = SidebarPeekPolicy(
        dwell: .milliseconds(120),
        grace: .milliseconds(250),
        edgeWidth: 14,
        dismissesOnWorkspaceActivation: true,
        isEnabled: true
    )

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - dwell: Rest time at the edge before revealing.
    ///   - grace: Delay between the last hold releasing and dismissal.
    ///   - edgeWidth: Width in points of the leading-edge reveal strip.
    ///   - dismissesOnWorkspaceActivation: Whether picking a workspace closes
    ///     the panel.
    ///   - isEnabled: Whether hover-reveal runs at all.
    public init(
        dwell: Duration,
        grace: Duration,
        edgeWidth: Double,
        dismissesOnWorkspaceActivation: Bool,
        isEnabled: Bool
    ) {
        self.dwell = dwell
        self.grace = grace
        self.edgeWidth = edgeWidth
        self.dismissesOnWorkspaceActivation = dismissesOnWorkspaceActivation
        self.isEnabled = isEnabled
    }
}
