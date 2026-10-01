import Foundation

/// Chrome-style group of screens inside one workspace: named, colored,
/// collapsible, members contiguous in screen order. Built from the daemon's
/// `screen_group` state resources by `ScreenStateSnapshot.decorate`.
public struct ScreenGroupSnapshot: Sendable, Hashable, Identifiable {
    public var id: ScreenGroupID
    public var name: String
    /// One of the nine group colors.
    public var color: String?
    public var collapsed: Bool
    /// Index of the first member in the workspace's screen list.
    public var start: Int
    public var count: Int
    /// Member screens in order.
    public var screens: [ScreenID]

    public init(id: ScreenGroupID, name: String = "", color: String? = nil, collapsed: Bool = false,
                start: Int = 0, screens: [ScreenID] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.collapsed = collapsed
        self.start = start
        self.count = screens.count
        self.screens = screens
    }
}
