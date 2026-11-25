public import AppKit

/// One row of a ``SidebarStatesPlaygroundSection``: real views the playground draws in each column's cell.
public struct SidebarStatesPlaygroundLook {
    /// The row's name beside its cells.
    public var title: String
    /// Adds the look's real views to `root` and returns the part of `root` to show, in `root`'s coordinates.
    ///
    /// The playground calls it once per column and appearance, with `root` alone in its own offscreen window, in the
    /// sheet's theme and appearance, while the column's `sidebar.density` and `sidebar.textSize` are set.
    public var stage: @MainActor (NSView) -> NSRect

    /// Creates a look.
    /// - Parameters:
    ///   - title: The row's name beside its cells.
    ///   - stage: Adds the look's views to the root it is given and returns the rect to show, in that root's coordinates.
    public init(title: String, stage: @escaping @MainActor (NSView) -> NSRect) {
        self.title = title
        self.stage = stage
    }
}
