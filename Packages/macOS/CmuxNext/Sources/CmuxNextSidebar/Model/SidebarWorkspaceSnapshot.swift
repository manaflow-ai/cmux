import CmuxNextDesign

/// The saved identity and appearance of a workspace row. Live status arrives from the daemon.
package nonisolated struct SidebarWorkspaceSnapshot: Codable, Hashable, Sendable {
    package var id: String
    package var machineID: String
    package var title: String
    /// `harness`, `browser` or `terminal`; absent in older snapshots.
    package var kind: String?
    /// The agent brand whose mark is the row's type glyph; absent in older snapshots.
    package var kindBrand: String?
    /// `symbol:<name>`, `swatch:<color>`, `emoji:<text>`, or `page:` for a page's favicon slot (restored as its globe).
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

    /// What `row` shows that a relaunch draws in its first frame. A page's favicon (or its globe) is saved as the
    /// page slot alone: the restored row draws the globe in the icon column, so its title starts where it stays and
    /// the live favicon replaces the globe in place.
    package init(row ws: SidebarWorkspace) {
        var icon: String?
        var tint: String?
        switch ws.icon {
        case let .symbol(name, color)?:
            icon = "symbol:" + name
            tint = color?.rawValue
        case let .swatch(color)?: icon = "swatch:" + color.rawValue
        case let .emoji(text, chip)?:
            icon = "emoji:" + text
            tint = chip?.rawValue
        case .favicon?, .pagePlaceholder?: icon = Self.pageIcon
        case nil: break
        }
        self.init(id: ws.id.rawValue, machineID: ws.machineID.rawValue, title: ws.title,
                  kind: ws.kind.rawValue, kindBrand: ws.kindBrand, icon: icon, iconTint: tint, color: ws.color?.rawValue)
    }

    /// The saved row, `.stale` until the live tree replaces it.
    package var restoredRow: SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), machineID: MachineID(machineID), title: title,
                         icon: icon.flatMap { Self.icon($0, tint: iconTint) }, color: color.flatMap(GroupColor.init(rawValue:)),
                         kind: SidebarWorkspaceKind(rawValue: kind ?? "terminal") ?? .terminal,
                         kindBrand: kindBrand, rowState: .stale)
    }

    /// The saved icon of a row that showed a page's favicon or its placeholder globe.
    static let pageIcon = "page:"

    private static func icon(_ value: String, tint: String?) -> WorkspaceIcon? {
        if value == pageIcon { return .pagePlaceholder }
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let kind = value[..<colon]
        let rest = String(value[value.index(after: colon)...])
        switch kind {
        case "symbol": return .symbol(rest, tint: tint.flatMap(GroupColor.init(rawValue:)))
        case "swatch": return GroupColor(rawValue: rest).map(WorkspaceIcon.swatch)
        case "emoji": return .emoji(rest, chip: tint.flatMap(GroupColor.init(rawValue:)))
        default: return nil
        }
    }
}
