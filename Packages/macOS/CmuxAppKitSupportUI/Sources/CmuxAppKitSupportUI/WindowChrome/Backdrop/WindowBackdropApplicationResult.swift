/// Result of applying a window backdrop plan.
public struct WindowBackdropApplicationResult {
    /// Whether the glass root hierarchy changed.
    public let didChangeGlassRoot: Bool

    /// Whether the resulting window uses glass.
    public let usesWindowGlass: Bool

    /// Creates a backdrop application result.
    public init(didChangeGlassRoot: Bool, usesWindowGlass: Bool) {
        self.didChangeGlassRoot = didChangeGlassRoot
        self.usesWindowGlass = usesWindowGlass
    }
}
