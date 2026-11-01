import Foundation

/// A menu row supplied by an agent page for the native tab-row toolbar.
public nonisolated struct PaneTabRowMenuItem: Equatable, Sendable {
    public let id: String
    public let label: String
    public let enabled: Bool
    public let checked: Bool?
    public let role: String?
    public let children: [PaneTabRowMenuItem]

    public init(id: String, label: String, enabled: Bool = true, checked: Bool? = nil,
                role: String? = nil, children: [PaneTabRowMenuItem] = []) {
        self.id = id
        self.label = label
        self.enabled = enabled
        self.checked = checked
        self.role = role
        self.children = children
    }
}

/// One content-supplied native control in the shared pane tab row.
public nonisolated struct PaneTabRowTool: Equatable, Sendable {
    public let id: String
    public let symbol: String
    public let label: String
    public let enabled: Bool
    public let toggled: Bool
    public let badge: String?
    public let menu: [PaneTabRowMenuItem]

    public init(id: String, symbol: String, label: String, enabled: Bool = true, toggled: Bool = false,
                badge: String? = nil, menu: [PaneTabRowMenuItem] = []) {
        self.id = id
        self.symbol = symbol
        self.label = label
        self.enabled = enabled
        self.toggled = toggled
        self.badge = badge
        self.menu = menu
    }
}
