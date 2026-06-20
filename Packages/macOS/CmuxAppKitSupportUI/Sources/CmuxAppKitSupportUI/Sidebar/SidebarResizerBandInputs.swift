public import AppKit

/// A snapshot of the window and divider geometry the resizer controller needs to
/// decide whether the live pointer sits in a divider hit band.
///
/// The controller never stores a back-reference to the host view (which is a
/// SwiftUI `struct` re-created every render); instead the host hands it a fresh
/// snapshot whenever band state must be recomputed. The window is required so the
/// controller can sample the live global pointer location in content space and the
/// content bounds. The leading divider is absolute (`leftDividerX`); the trailing
/// divider is defined as an inset from the content's right edge
/// (`rightSidebarWidth`) so the controller resolves its content-space x as
/// `contentBounds.maxX - rightSidebarWidth`, matching the legacy view math.
public struct SidebarResizerBandInputs {
    /// The window whose content view supplies the coordinate space and bounds.
    public weak var window: NSWindow?
    /// Whether the leading workspace-sidebar divider is shown.
    public var leftDividerVisible: Bool
    /// The leading divider's x position in content space.
    public var leftDividerX: CGFloat
    /// Whether the trailing file-explorer divider is shown.
    public var rightDividerVisible: Bool
    /// The trailing divider's width (inset from the content's right edge).
    public var rightSidebarWidth: CGFloat

    /// Creates a band-inputs snapshot.
    /// - Parameters:
    ///   - window: The window supplying the content coordinate space.
    ///   - leftDividerVisible: Whether the leading sidebar divider is shown.
    ///   - leftDividerX: The leading divider's x position in content space.
    ///   - rightDividerVisible: Whether the trailing explorer divider is shown.
    ///   - rightSidebarWidth: The trailing divider's width (inset from the
    ///     content's right edge).
    public init(
        window: NSWindow?,
        leftDividerVisible: Bool,
        leftDividerX: CGFloat,
        rightDividerVisible: Bool,
        rightSidebarWidth: CGFloat
    ) {
        self.window = window
        self.leftDividerVisible = leftDividerVisible
        self.leftDividerX = leftDividerX
        self.rightDividerVisible = rightDividerVisible
        self.rightSidebarWidth = rightSidebarWidth
    }
}
