import AppKit
import CmuxNextDesign

/// The Sidebar States Playground's "Workspace colors" sheet (Lawrence 2026-11-20, "make many versions of 'colors' we
/// need this to be better"): the real ``WorkspaceRowView`` with a picked color in each treatment, a bar's width,
/// length, radius and place, its ink (the full swatch, a quiet or a muted one), a wash over the row, a tinted title, the
/// dot, the filled row and none, at every density and text size, in the light and dark sheets. Each look draws a long
/// blue title at rest and selected, a green and a purple row, and an uncolored row at rest and selected.
@MainActor
struct WorkspaceColorPlaygroundSection {
    /// One treatment: how the sheet names it, the settings style it draws with and its ``WorkspaceRailLook``.
    struct Variant {
        var title: String
        var style: WorkspaceColorIndicatorStyle = .leftRail
        var look = WorkspaceRailLook.standard
        var showsColors = true
    }

    /// The rows each look shows, top to bottom: a color (nil for none), a title and whether the row is selected.
    static let rows: [(color: GroupColor?, title: String, selected: Bool)] = [
        (.blue, "workspace-1005 · fix the sidebar colors and the bookmark popover contrast", false),
        (.blue, "workspace-1005 · fix the sidebar colors and the bookmark popover contrast", true),
        (.green, "Deploy staging", false),
        (.purple, "Review the tooltip redesign", false),
        (nil, "Hide Spaces by default", false),
        (nil, "Bookmark popover contrast", true),
    ]
    /// The rows' width: the app's default sidebar width less its insets.
    static let width: CGFloat = 240

    /// Every treatment the sheet draws, the app's own first.
    static var variants: [Variant] {
        [
            Variant(title: Strings.standard),
            Variant(title: Strings.stripe, look: WorkspaceRailLook(barWidth: 3, length: .row, lead: 1.5, ink: .swatch)),
            Variant(title: Strings.hairline, look: WorkspaceRailLook(barWidth: 2, length: .row, lead: 0, rounded: false, ink: .quiet)),
            Variant(title: Strings.mutedStripe, look: WorkspaceRailLook(barWidth: 3, length: .row, lead: 1.5, ink: .muted)),
            Variant(title: Strings.tick, look: WorkspaceRailLook(barWidth: 3, length: .line, lead: 3, ink: .swatch)),
            Variant(title: Strings.wash, look: WorkspaceRailLook(wash: 0.12)),
            Variant(title: Strings.washHairline,
                    look: WorkspaceRailLook(barWidth: 2, length: .row, lead: 0, rounded: false, ink: .quiet, wash: 0.08)),
            Variant(title: Strings.titleTint, look: WorkspaceRailLook(titleTint: 0.45)),
            Variant(title: Strings.pillTitleTint,
                    look: WorkspaceRailLook(barWidth: 3, length: .line, lead: 1.5, ink: .quiet, titleTint: 0.25)),
            Variant(title: Strings.dot, style: .dot),
            Variant(title: Strings.fill, style: .fill),
            Variant(title: Strings.none, showsColors: false),
        ]
    }

    /// The sheet: one look per treatment.
    func section() -> SidebarStatesPlaygroundSection {
        SidebarStatesPlaygroundSection(title: Strings.title, looks: Self.variants.map(look))
    }

    private func look(_ variant: Variant) -> SidebarStatesPlaygroundLook {
        SidebarStatesPlaygroundLook(title: variant.title) { root in
            let height = SidebarDensityTokens.rowHeight, pitch = height + 2
            let total = pitch * CGFloat(Self.rows.count)
            let frame = NSRect(x: 0, y: root.bounds.height - total, width: Self.width, height: total)
            var options = SidebarLayoutOptions()
            (options.colorIndicator, options.showsColors) = (variant.style, variant.showsColors)
            for (index, sample) in Self.rows.enumerated() {
                let ws = SidebarWorkspace(id: WorkspaceID("ws_color_\(index)"), title: sample.title,
                                          icon: sample.color.map(WorkspaceIcon.swatch), color: sample.color)
                var content = options.rowContent(ws, machine: nil)
                content.railLook = variant.look
                let row = SidebarRow(key: .workspace(ws.id), y: 0, height: height, section: .pinned, group: nil, siblingIndex: index,
                                     parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                                     content: content)
                let view = WorkspaceRowView(key: row.key)
                view.frame = NSRect(x: 0, y: frame.maxY - pitch * CGFloat(index + 1) + 1, width: Self.width, height: height)
                root.addSubview(view)
                view.configure(ws, row: row)
                view.isSelected = sample.selected
                view.layoutSubtreeIfNeeded()
                view.needsDisplay = true
            }
            return frame
        }
    }

    private enum Strings {
        static var title: String {
            String(localized: "sidebar.workspaceColorPlayground.title", defaultValue: "Workspace colors", bundle: .module)
        }
        static var standard: String {
            String(localized: "sidebar.workspaceColorPlayground.standard", defaultValue: "Quiet pill (app)", bundle: .module)
        }
        static var stripe: String {
            String(localized: "sidebar.workspaceColorPlayground.stripe", defaultValue: "Full stripe (before)", bundle: .module)
        }
        static var hairline: String {
            String(localized: "sidebar.workspaceColorPlayground.hairline", defaultValue: "Hairline on the edge", bundle: .module)
        }
        static var mutedStripe: String {
            String(localized: "sidebar.workspaceColorPlayground.mutedStripe", defaultValue: "Muted stripe", bundle: .module)
        }
        static var tick: String {
            String(localized: "sidebar.workspaceColorPlayground.tick", defaultValue: "Vivid tick, inset", bundle: .module)
        }
        static var wash: String {
            String(localized: "sidebar.workspaceColorPlayground.wash", defaultValue: "Wash", bundle: .module)
        }
        static var washHairline: String {
            String(localized: "sidebar.workspaceColorPlayground.washHairline", defaultValue: "Wash and hairline", bundle: .module)
        }
        static var titleTint: String {
            String(localized: "sidebar.workspaceColorPlayground.titleTint", defaultValue: "Tinted title", bundle: .module)
        }
        static var pillTitleTint: String {
            String(localized: "sidebar.workspaceColorPlayground.pillTitleTint", defaultValue: "Pill and tinted title", bundle: .module)
        }
        static var dot: String {
            String(localized: "sidebar.workspaceColorPlayground.dot", defaultValue: "Dot before the name", bundle: .module)
        }
        static var fill: String {
            String(localized: "sidebar.workspaceColorPlayground.fill", defaultValue: "Filled row", bundle: .module)
        }
        static var none: String {
            String(localized: "sidebar.workspaceColorPlayground.none", defaultValue: "No color", bundle: .module)
        }
    }
}
