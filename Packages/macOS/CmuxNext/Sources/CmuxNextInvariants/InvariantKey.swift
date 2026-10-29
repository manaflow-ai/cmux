/// A kind of state the invariant rules read (plans/cmux-next/invariants-DESIGN.md section 3.3). A producer that
/// changes the state touches its key with a subject; a turn runs only the rules whose `reads` hold a touched key.
/// It compiles in every build, because a Release probe call names it (and does nothing with it).
public struct InvariantKey: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(stringLiteral value: String) { rawValue = value }

    public var description: String { rawValue }

    /// A window's focus model, key window, first responder or activation; a key or mouse press.
    public static let focus: InvariantKey = "focus"
    /// A shown or hidden view, pane, window or node.
    public static let visibility: InvariantKey = "visibility"
    /// A window's or a pane's frame, screen or backing scale.
    public static let paneFrame: InvariantKey = "paneFrame"
    /// A terminal's grid.
    public static let grid: InvariantKey = "grid"
    /// The tabs a strip shows or a pane holds; a tab drag's end.
    public static let tabs: InvariantKey = "tabs"
    /// What a pane presents (`presentationChanges`).
    public static let presentation: InvariantKey = "presentation"
    /// A spring or slide step.
    public static let motion: InvariantKey = "motion"
    /// The set of windows.
    public static let windows: InvariantKey = "windows"
    /// A write of a daemon mirror.
    public static let mirror: InvariantKey = "mirror"
    /// The hover card machine.
    public static let hover: InvariantKey = "hover"
    /// A hold, park or stand-in that began or ended.
    public static let holds: InvariantKey = "holds"
}
