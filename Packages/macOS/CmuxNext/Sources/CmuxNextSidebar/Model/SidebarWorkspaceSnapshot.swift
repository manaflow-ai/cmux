/// The saved identity and appearance of a workspace row. Live status arrives from the daemon.
package nonisolated struct SidebarWorkspaceSnapshot: Codable, Hashable, Sendable {
    package var id: String
    package var machineID: String
    package var title: String
    /// `harness`, `browser` or `terminal`; absent in older snapshots.
    package var kind: String?
    /// The agent brand whose mark is the row's type glyph; absent in older snapshots.
    package var kindBrand: String?
    /// `symbol:<name>`, `swatch:<color>` or `emoji:<text>`.
    package var icon: String?
    package var iconTint: String?
    /// The workspace's own color, for a filled or railed row; absent in older snapshots.
    package var color: String?

    package init(id: String, machineID: String, title: String, kind: String? = nil,
                 kindBrand: String? = nil, icon: String? = nil, iconTint: String? = nil, color: String? = nil) {
        self.id = id
        self.machineID = machineID
        self.title = title
        self.kind = kind
        self.kindBrand = kindBrand
        self.icon = icon
        self.iconTint = iconTint
        self.color = color
    }
}
