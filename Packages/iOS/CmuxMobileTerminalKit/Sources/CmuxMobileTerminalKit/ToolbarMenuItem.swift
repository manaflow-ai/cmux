public import Foundation

/// One selectable child inside a custom toolbar dropdown menu.
///
/// Menu items use the same payload model as top-level custom toolbar actions, so
/// selecting a row can type text, send a key combo, or open a nested menu.
public struct ToolbarMenuItem: Codable, Equatable, Sendable, Identifiable {
    /// Stable identifier for the menu row.
    public let id: UUID
    /// Label shown in the dropdown menu.
    public var title: String
    /// Optional SF Symbol name shown beside the menu label.
    public var symbolName: String?
    /// The action performed when this menu row is selected.
    public var payload: ToolbarActionPayload

    /// Creates a toolbar menu item.
    /// - Parameters:
    ///   - id: Stable identifier. Defaults to a fresh `UUID`.
    ///   - title: Label shown in the dropdown menu.
    ///   - symbolName: Optional SF Symbol name shown beside the menu label.
    ///   - payload: The action performed when selected.
    public init(
        id: UUID = UUID(),
        title: String,
        symbolName: String? = nil,
        payload: ToolbarActionPayload
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.payload = payload
    }

    /// The bytes sent to the terminal when this item is selected, or `nil` when
    /// the payload is a submenu or resolves to no bytes.
    public var output: Data? {
        payload.output
    }

    /// Child rows when this item opens a nested dropdown menu.
    public var menuItems: [ToolbarMenuItem] {
        payload.menuItems
    }

    /// Whether this item opens a nested dropdown menu.
    public var isMenu: Bool {
        payload.isMenu
    }
}
