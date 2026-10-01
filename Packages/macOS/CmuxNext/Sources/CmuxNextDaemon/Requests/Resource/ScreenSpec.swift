import Foundation

/// What a new screen starts with: its name, then the screen state applied
/// right after it is created (`DaemonConnection.newScreen(in:spec:)`).
public struct ScreenSpec: Sendable, Hashable {
    public var name: String?
    public var color: String?
    public var icon: String?
    public var pinned: Bool?
    /// Index in the workspace's screen list (default: the end).
    public var index: Int?
    /// Joins this screen group.
    public var group: ScreenGroupID?

    public init(name: String? = nil, color: String? = nil, icon: String? = nil, pinned: Bool? = nil, index: Int? = nil,
                group: ScreenGroupID? = nil) {
        self.name = name
        self.color = color
        self.icon = icon
        self.pinned = pinned
        self.index = index
        self.group = group
    }

    public var isEmpty: Bool { self == ScreenSpec() }
}
