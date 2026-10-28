/// What one tab drag did, counted for its work budget (TabDragWorkTests): the drag session's
/// share; the ghost, the layouts and the strips count their own.
public nonisolated struct TabDragWork: Equatable, Sendable {
    /// Full hit tests: sidebar, strips and layout asked at a point.
    public var hitTests = 0
    /// `NSApp.orderedWindows` walks for the window under a point.
    public var windowOrderReads = 0
    /// Resolver contexts built from the source pane's live model.
    public var contextBuilds = 0

    public init() {}
}
