import AppKit
import CmuxNextDesign
import QuartzCore

/// The Sidebar States Playground's "Group backgrounds" sheet (Lawrence 2026-11-05: "invariant: groups must always have
/// a visible bg color, groups should support both glassy and solid bgs too"): the real ``GroupHeaderRowView`` for a
/// group with no color, each palette color and a custom color, open and collapsed, in each
/// `sidebar.groupHeader.background` look (solid and glass, at rest and hovered), at every density and text size, in
/// the light and dark sheets. Glass stands over a strip of color so its see-through shows.
@MainActor
struct GroupBackgroundPlaygroundSection {
    /// The groups each look shows, top to bottom: no color first, then the editor's order, then a custom color.
    static let tints: [GroupTint] = [.none] + GroupColor.editorOrder.map { .palette($0) } + [.custom(ThemeRGB(hex: 0x336699))]
    /// The headers' width: the app's default sidebar width less its insets.
    static let width: CGFloat = 240

    /// The sheet: one look per background style and state.
    func section() -> SidebarStatesPlaygroundSection {
        SidebarStatesPlaygroundSection(title: Strings.title, looks: [
            look(Strings.solid, style: .solid, hovered: false),
            look(Strings.glass, style: .glass, hovered: false),
            look(Strings.solidHovered, style: .solid, hovered: true),
            look(Strings.glassHovered, style: .glass, hovered: true),
        ])
    }

    private func look(_ title: String, style: SidebarGroupBackgroundStyle, hovered: Bool) -> SidebarStatesPlaygroundLook {
        SidebarStatesPlaygroundLook(title: title) { root in
            let pitch = SidebarDensityTokens.rowHeight + 2
            let height = pitch * CGFloat(Self.tints.count)
            let frame = NSRect(x: 0, y: root.bounds.height - height, width: Self.width, height: height)
            if style == .glass {
                // What the window's glass shows through: a strip of color under the headers' trailing half.
                let strip = CAGradientLayer()
                strip.colors = [NSColor.systemPink, .systemOrange, .systemTeal].map(\.cgColor)
                strip.startPoint = CGPoint(x: 0, y: 0)
                strip.endPoint = CGPoint(x: 0, y: 1)
                strip.frame = CGRect(x: Self.width * 0.55, y: frame.minY, width: Self.width * 0.45, height: height)
                root.layer?.addSublayer(strip)
            }
            for (index, tint) in Self.tints.enumerated() {
                let id = GroupID("grp_background_\(index)")
                let header = GroupHeaderRowView(key: .group(id))
                header.frame = NSRect(x: 0, y: frame.maxY - pitch * CGFloat(index + 1) + 1, width: Self.width,
                                      height: SidebarDensityTokens.rowHeight)
                root.addSubview(header)
                let collapsed = index.isMultiple(of: 2)
                let group = SidebarGroup(id: id, name: Strings.name(tint), custom: tint.wire, isCollapsed: collapsed, workspaces: [])
                let row = SidebarRow(key: .group(id), y: 0, height: header.frame.height, section: .pinned, group: id, siblingIndex: index,
                                     parentIndex: nil, isLastInGroup: false, isCollapsed: collapsed, childCount: 3, groupColor: nil)
                header.configure(group, row: row, details: GroupHeaderDetails(memberCount: true, background: style), animated: false)
                header.isHovered = hovered
                header.layoutSubtreeIfNeeded()
                header.needsDisplay = true
            }
            return frame
        }
    }

    private enum Strings {
        static var title: String { String(localized: "sidebar.groupBackgroundPlayground.title", defaultValue: "Group backgrounds", bundle: .module) }
        static var solid: String { String(localized: "sidebar.groupBackgroundPlayground.solid", defaultValue: "Solid", bundle: .module) }
        static var glass: String { String(localized: "sidebar.groupBackgroundPlayground.glass", defaultValue: "Glass", bundle: .module) }
        static var solidHovered: String {
            String(localized: "sidebar.groupBackgroundPlayground.solidHovered", defaultValue: "Solid, hovered", bundle: .module)
        }
        static var glassHovered: String {
            String(localized: "sidebar.groupBackgroundPlayground.glassHovered", defaultValue: "Glass, hovered", bundle: .module)
        }
        static func name(_ tint: GroupTint) -> String {
            tint.isNone ? String(localized: "sidebar.groupBackgroundPlayground.noColor", defaultValue: "No color", bundle: .module) : tint.wire
        }
    }
}
