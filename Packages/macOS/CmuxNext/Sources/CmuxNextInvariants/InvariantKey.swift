/// A kind of state the invariant rules read (plans/cmux-next/invariants-DESIGN.md section 3.3). A producer that
/// changes the state touches its key with a subject; a turn runs only the rules whose `reads` hold a touched key.
/// It compiles in every build, because a Release probe call names it (and does nothing with it). The named keys are
/// computed and emitted into the caller, so a Release probe call at a write reads no global (no `swift_once`) and the
/// empty inlined call leaves nothing behind.
public struct InvariantKey: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    @inlinable public init(rawValue: String) { self.rawValue = rawValue }

    @inlinable public init(stringLiteral value: String) { rawValue = value }

    public var description: String { rawValue }

    /// A window's focus model, key window, first responder or activation; a key or mouse press.
    @_alwaysEmitIntoClient public static var focus: InvariantKey { "focus" }
    /// A shown or hidden view, pane, window or node.
    @_alwaysEmitIntoClient public static var visibility: InvariantKey { "visibility" }
    /// A window's or a pane's frame, screen or backing scale.
    @_alwaysEmitIntoClient public static var paneFrame: InvariantKey { "paneFrame" }
    /// A terminal's grid.
    @_alwaysEmitIntoClient public static var grid: InvariantKey { "grid" }
    /// The tabs a strip shows or a pane holds; a tab drag's end.
    @_alwaysEmitIntoClient public static var tabs: InvariantKey { "tabs" }
    /// What a pane presents (`presentationChanges`).
    @_alwaysEmitIntoClient public static var presentation: InvariantKey { "presentation" }
    /// A spring or slide step.
    @_alwaysEmitIntoClient public static var motion: InvariantKey { "motion" }
    /// The set of windows.
    @_alwaysEmitIntoClient public static var windows: InvariantKey { "windows" }
    /// A write of a daemon mirror.
    @_alwaysEmitIntoClient public static var mirror: InvariantKey { "mirror" }
    /// The hover card machine.
    @_alwaysEmitIntoClient public static var hover: InvariantKey { "hover" }
    /// A hold, park or stand-in that began or ended.
    @_alwaysEmitIntoClient public static var holds: InvariantKey { "holds" }
}
