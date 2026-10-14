import AppKit
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

/// `debug.sidebar_rows`: each window's workspace-list rows with their
/// views (frame, alpha, in the list, the group it lists in), the selection and the dragged keys,
/// so a live drag can be checked row by row (R77, nxdog30), and the layout
/// items (Home, App Store, Settings) and the + button with their frames, so a proof clicks them.
/// `menu_x`, `menu_y` (window points from the top-left, as `debug.mouse`) add
/// the first window's `menu`: the titles a right-click there opens, built by
/// the list's own `menu(for:)` without showing it, and `submenus`: each
/// folder's titles by the folder's title.
enum DebugSidebarRows {
    static func report(_ params: [String: JSONValue] = [:], services: AppServices) -> JSONValue {
        if let motion = params["motion"]?.stringValue { return self.motion(motion == "start", services: services) }
        guard let x = params["menu_x"]?.doubleValue, let y = params["menu_y"]?.doubleValue else { return rows(services: services) }
        let menu = services.windows.controllers.first.flatMap {
            $0.sidebar.container.debugMenu(atWindowPoint: CGPoint(x: x, y: y))
        }
        func titles(_ menu: NSMenu) -> JSONValue { .array(menu.items.map { .string($0.isSeparatorItem ? "-" : $0.title) }) }
        let submenus = (menu?.items ?? []).compactMap { item in item.submenu.map { (item.title, titles($0)) } }
        return .object(["menu": menu.map(titles) ?? .null,
                        "submenus": .object(Dictionary(submenus, uniquingKeysWith: { first, _ in first }))])
    }

    /// `{"motion": "start"|"stop"}`: the first window's per-display-frame
    /// sidebar samples (SidebarMotionFrame); stop returns them as
    /// {t, scroll, lift, work_ms, revision, settling, views: {key: [x, y, w, h, opacity]}}.
    private static func motion(_ start: Bool, services: AppServices) -> JSONValue {
        guard let sidebar = services.windows.controllers.first?.sidebar.container.sidebarView else { return .null }
        func box(_ r: CGRect) -> JSONValue { .array([r.minX, r.minY, r.width, r.height].map { .number(Double($0)) }) }
        let frames = sidebar.debugMotion(start: start)
        return .object(["frames": .array(frames.map { frame in
            .object(["t": .number(frame.time), "scroll": .number(Double(frame.scrollY)), "lift": frame.lift.map(box) ?? .null,
                     "work_ms": .number(frame.dragWorkMs), "revision": .number(Double(frame.revision)), "settling": .bool(frame.settling), "views": .object(Dictionary(uniqueKeysWithValues: frame.views.map { key, rect in
                        (key, .array([rect.minX, rect.minY, rect.width, rect.height, CGFloat(frame.opacity[key] ?? 1)].map { .number(Double($0)) }))
                     }))])
        })])
    }

    private static func rows(services: AppServices) -> JSONValue {
        // `doc`: the sidebar document path is on, and the mirror's FFI calls so far (two per drag: drag_begin, the drop).
        .object(["doc": .object(["active": .bool(SidebarDocStore.current?.isActive == true), "ffi_calls": .object(SidebarMirror.calls.mapValues { .number(Double($0)) })]),
                 "windows": .array(services.windows.controllers.map { controller in
            let sidebar = controller.sidebar.container.sidebarView
            let (rows, selection, dragging) = sidebar.debugRows()
            return .object([
                "window": .string(controller.state.id),
                "selection": .array(selection.map(JSONValue.string)),
                "dragging": .array(dragging.map(JSONValue.string)),
                "drop": sidebar.debugDropProbe().map(probe) ?? .null,
                "paging": .object(sidebar.debugPaging().mapValues(JSONValue.string)),
                "items": .array(items(of: controller)),
                // Section headers the band or a list block draws (an empty custom section has no item to aim a drop at).
                "sections": .array(controller.sidebar.container.sidebarView.debugSectionHeaders().map { header in
                    .object(["id": .string(header.id), "title": header.title.map(JSONValue.string) ?? .null, "window_frame": rect(header.frame)])
                }),
                // Every shown section's arrangement (align, gap) and item count: reads alignment, spacing and reset edits back.
                "layout_sections": .array(sidebar.debugLayoutSections().map { section in
                    .object(["id": .string(section.id), "title": section.title.map(JSONValue.string) ?? .null, "align": .string(section.align),
                             "gap": section.gap.map { .number(Double($0)) } ?? .null, "items": .number(Double(section.items))])
                }),
                "status_glyphs": .array(sidebar.debugStatusGlyphs().map(statusGlyph)),
                "new_button": sidebar.debugNewButtonFrame().map(rect) ?? .null,
                "rows": .array(rows.map { row in
                    .object([
                        "key": .string(row.key), "title": row.title.map(JSONValue.string) ?? .null,
                        "frame": rect(row.frame), "window_frame": rect(row.windowFrame), "view_frame": row.viewFrame.map(rect) ?? .null,
                        "view_alpha": row.viewAlpha.map { .number(Double($0)) } ?? .null,
                        "in_list": .bool(row.inList), "suppressed": .bool(row.suppressed), "selected": .bool(row.selected),
                        "muted": .bool(row.muted), "activity": row.activity.map(JSONValue.string) ?? .null,
                        "icon": row.icon.map(JSONValue.string) ?? .null,
                        "shown_frame": row.shownFrame.map(rect) ?? .null, "clips": .bool(row.clips),
                        "group": row.group.map(JSONValue.string) ?? .null,
                        "detail": row.detail.map(JSONValue.string) ?? .null,
                        "unread": row.unread.map(JSONValue.string) ?? .null, "progress": .bool(row.progress), "shows_working": .bool(row.showsWorking),
                        "fill": .bool(row.fill), "hovered": .bool(row.hovered),
                        "disclosure": row.disclosureIcon.map { icon in
                            .object(["icon": .string(icon), "frame": row.disclosureFrame.map(rect) ?? .null, "shown": .bool(row.disclosureShown)])
                        } ?? .null,
                    ])
                }),
            ])
        })])
    }

    /// The window's sidebar layout items (debug.sidebar_rows "items").
    static func items(of controller: WindowController) -> [JSONValue] {
        controller.sidebar.container.sidebarView.debugLayoutItems().map { item in
            .object([
                "id": .string(item.id), "ref_kind": .string(item.refKind), "ref": .string(item.ref),
                "region": .string(item.region), "section": .string(item.section),
                "section_title": item.sectionTitle.map(JSONValue.string) ?? .null, "active": .bool(item.isActive),
                "window_frame": item.windowFrame.map(rect) ?? .null,
            ])
        }
    }

    /// A shown status glyph (sidebar-status-glyph-live.py); rects as [x, y, width, height].
    private static func statusGlyph(_ g: SidebarDebugStatusGlyph) -> JSONValue {
        func box(_ r: CGRect?) -> JSONValue { r.map { r in .array([r.minX, r.minY, r.width, r.height].map { .number((Double($0) * 100).rounded() / 100) }) } ?? .null }
        func num(_ v: CGFloat?) -> JSONValue { v.map { .number(Double($0)) } ?? .null }
        return .object([
            "state": .string(g.state), "frame": box(g.frame), "scale": num(g.scale), "badge_height": num(g.badgeHeight),
            "drawn": box(g.drawn), "glyph_side": num(g.glyphSide), "badge": box(g.badge),
            "soft_1x": g.soft1x.map(JSONValue.number) ?? .null, "soft_2x": g.soft2x.map(JSONValue.number) ?? .null,
            "title": g.title.map { .object(["text": .string($0), "cap_center_y": num(g.titleCapCenterY)]) } ?? .null,
            "glyph": .string(g.glyph), "animation": g.animation.map(JSONValue.string) ?? .null,
            "phase": g.phase.map(JSONValue.number) ?? .null,
        ])
    }

    /// The last drop resolution of a live drag: card edge, hit row, zone, target.
    private static func probe(_ p: SidebarDropProbe) -> JSONValue {
        func num(_ v: CGFloat?) -> JSONValue { v.map { .number(Double($0)) } ?? .null }
        return .object([
            "edge": .string(p.edge), "display_y": .number(Double(p.displayY)), "base_y": num(p.baseY),
            "row": p.row.map(JSONValue.string) ?? .null, "fraction": num(p.fraction),
            "target": p.target.map(JSONValue.string) ?? .null, "indicator": p.indicator.map(JSONValue.string) ?? .null, "refusal": p.refusal.map(JSONValue.string) ?? .null,
        ])
    }

    private static func rect(_ r: CGRect) -> JSONValue {
        .object(["x": .number(r.minX), "y": .number(r.minY), "width": .number(r.width), "height": .number(r.height)])
    }
}
