import AppKit

/// `debug.sidebar_rows` as a JSONSerialization object graph (nil is NSNull),
/// so the app adds only its window fields. Rects are {x, y, width, height}.
extension SidebarViewComponents {
    /// One window's sidebar: rows, selection, drag and drop state, paging,
    /// section headers and arrangements, status glyphs, layout items, + button.
    public func debugReport() -> [String: Any] {
        let (rows, selection, dragging) = debugRows()
        return [
            "selection": selection, "dragging": dragging, "drag_active": debugDragActive(),
            "drop": debugDropProbe().map(Self.probe) ?? NSNull(), "paging": debugPaging(), "items": debugLayoutItemsReport(),
            // Section headers the band or a list block draws (an empty custom section has no item to aim a drop at).
            "sections": debugSectionHeaders().map { ["id": $0.id, "title": Self.opt($0.title), "window_frame": Self.rect($0.frame)] },
            // Every shown section's arrangement (align, gap) and item count: reads alignment, spacing and reset edits back.
            "layout_sections": debugLayoutSections().map {
                ["id": $0.id, "title": Self.opt($0.title), "align": $0.align, "gap": Self.opt($0.gap.map(Double.init)), "items": $0.items]
            },
            "status_glyphs": debugStatusGlyphs().map(Self.statusGlyph),
            "new_button": debugNewButtonFrame().map(Self.rect) ?? NSNull(),
            "rows": rows.map(Self.row),
        ]
    }

    /// The layout items (Home, App Store, Settings) with their frames.
    public func debugLayoutItemsReport() -> [[String: Any]] {
        debugLayoutItems().map { item in
            ["id": item.id, "ref_kind": item.refKind, "ref": item.ref, "region": item.region, "section": item.section,
             "section_title": Self.opt(item.sectionTitle), "active": item.isActive, "window_frame": item.windowFrame.map(Self.rect) ?? NSNull()]
        }
    }

    /// `{"motion": "start"|"stop"}`: the per-display-frame samples (SidebarMotionFrame); stop returns them as
    /// {t, scroll, lift, work_ms, revision, settling, views: {key: [x, y, w, h, opacity]}}.
    public func debugMotionReport(start: Bool) -> [String: Any] {
        func box(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }
        return ["frames": debugMotion(start: start).map { frame -> [String: Any] in
            ["t": frame.time, "scroll": Double(frame.scrollY), "lift": frame.lift.map(box) ?? NSNull(), "work_ms": frame.dragWorkMs,
             "revision": Double(frame.revision), "settling": frame.settling,
             "views": Dictionary(uniqueKeysWithValues: frame.views.map { key, rect in (key, box(rect) + [Double(frame.opacity[key] ?? 1)]) })]
        }]
    }

    private static func row(_ row: SidebarDebugRow) -> [String: Any] {
        [
            "key": row.key, "title": opt(row.title), "frame": rect(row.frame), "window_frame": rect(row.windowFrame),
            "view_frame": row.viewFrame.map(rect) ?? NSNull(), "view_alpha": opt(row.viewAlpha.map(Double.init)), "row_state": opt(row.rowState),
            "directory": opt(row.directory), "in_list": row.inList, "suppressed": row.suppressed, "selected": row.selected, "muted": row.muted, "activity": opt(row.activity),
            "icon": opt(row.icon), "icon_address": opt(row.iconAddress), "shown_frame": row.shownFrame.map(rect) ?? NSNull(), "clips": row.clips,
            "group": opt(row.group), "item": opt(row.item), "kind": opt(row.itemKind), "detail": opt(row.detail), "unread": opt(row.unread),
            "progress": row.progress, "shows_working": row.showsWorking, "fill": row.fill, "hovered": row.hovered, "archived": row.archived,
            "disclosure": row.disclosureIcon.map { icon -> Any in
                ["icon": icon, "frame": row.disclosureFrame.map(rect) ?? NSNull(), "shown": row.disclosureShown]
            } ?? NSNull(),
        ]
    }

    /// A shown status glyph (sidebar-status-glyph-live.py); rects as [x, y, width, height] rounded to 0.01.
    private static func statusGlyph(_ g: SidebarDebugStatusGlyph) -> [String: Any] {
        func box(_ r: CGRect?) -> Any { r.map { r in [r.minX, r.minY, r.width, r.height].map { (Double($0) * 100).rounded() / 100 } } ?? NSNull() }
        func num(_ v: CGFloat?) -> Any { opt(v.map(Double.init)) }
        return [
            "state": g.state, "frame": box(g.frame), "scale": num(g.scale), "badge_height": num(g.badgeHeight),
            "drawn": box(g.drawn), "glyph_side": num(g.glyphSide), "badge": box(g.badge),
            "soft_1x": opt(g.soft1x), "soft_2x": opt(g.soft2x),
            "title": g.title.map { ["text": $0, "cap_center_y": num(g.titleCapCenterY)] as [String: Any] } ?? NSNull(),
            "glyph": g.glyph, "animation": opt(g.animation), "phase": opt(g.phase),
        ]
    }

    /// The last drop resolution of a live drag: card edge, hit row, zone, target.
    private static func probe(_ p: SidebarDropProbe) -> [String: Any] {
        [
            "edge": p.edge, "display_y": Double(p.displayY), "base_y": opt(p.baseY.map(Double.init)), "row": opt(p.row),
            "fraction": opt(p.fraction.map(Double.init)), "target": opt(p.target), "indicator": opt(p.indicator), "refusal": opt(p.refusal),
        ]
    }

    private static func opt(_ value: Any?) -> Any { value ?? NSNull() }

    private static func rect(_ r: CGRect) -> [String: Any] {
        ["x": Double(r.minX), "y": Double(r.minY), "width": Double(r.width), "height": Double(r.height)]
    }
}
