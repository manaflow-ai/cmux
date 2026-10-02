/// Which docks own the screen frame's corners (plans/cmux-next/layout-model.md,
/// decision L2). cmux.json `layout.frameOrientation` sets the default for new
/// screens; every op, focus and drop rule is the same in both.
public nonisolated enum FrameOrientation: String, Hashable, Sendable, CaseIterable {
    /// Left and right docks run the full height; top and bottom docks sit
    /// between them (default).
    case columnMajor
    /// Top and bottom docks run the full width; left and right docks sit
    /// between them.
    case rowMajor
}
