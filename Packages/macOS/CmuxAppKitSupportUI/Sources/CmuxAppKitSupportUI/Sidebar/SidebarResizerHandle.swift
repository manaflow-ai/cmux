/// Identifies which of the two sidebar dividers a resizer handle drives.
///
/// `cmux` shows a leading workspace sidebar divider and a trailing file-explorer
/// (right sidebar) divider. Hover, drag, and cursor state are tracked per handle
/// so that hovering one divider does not release the resize cursor while the
/// other is still engaged.
public enum SidebarResizerHandle: Hashable, Sendable {
    /// The leading workspace-sidebar divider.
    case divider
    /// The trailing file-explorer (right sidebar) divider.
    case explorerDivider
}
