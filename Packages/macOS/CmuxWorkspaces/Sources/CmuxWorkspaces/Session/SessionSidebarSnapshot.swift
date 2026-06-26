/// The persisted sidebar state inside a session snapshot.
///
/// A pure leaf value carrying whether the sidebar `isVisible`, its `selection`
/// (`SessionSidebarSelection`), and its restored `width`. The on-disk wire
/// format is owned by the app's `SessionWindowSnapshot`; encoding stays
/// byte-identical to the legacy app-target definition (default `Codable`
/// synthesis over the same stored-property set).
public struct SessionSidebarSnapshot: Codable, Sendable {
    /// Whether the sidebar was visible.
    public var isVisible: Bool
    /// Which top-level pane the sidebar showed.
    public var selection: SessionSidebarSelection
    /// The sidebar's restored width, when recorded.
    public var width: Double?

    /// Creates a persisted sidebar snapshot.
    public init(
        isVisible: Bool,
        selection: SessionSidebarSelection,
        width: Double? = nil
    ) {
        self.isVisible = isVisible
        self.selection = selection
        self.width = width
    }
}
