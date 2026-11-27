/// Progress shown in the workspace's sidebar row (0...1 plus optional label).
public struct SidebarProgressState: Equatable, Sendable {
    /// Progress fraction in 0...1.
    public let value: Double
    /// Optional label shown next to the bar.
    public let label: String?

    /// Creates a progress state.
    public init(value: Double, label: String?) {
        self.value = value
        self.label = label
    }
}
