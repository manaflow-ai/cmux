public import AppKit

/// One drawn workspace-list row, for `debug.sidebar_rows`: what the list
/// shows and what its view draws (frame, alpha, in the list or not).
public struct SidebarDebugRow: Sendable {
    public var key: String
    public var title: String?
    public var frame: CGRect
    /// The row in window points from the top-left (as `debug.mouse` takes them).
    public var windowFrame: CGRect
    public var viewFrame: CGRect?
    public var viewAlpha: CGFloat?
    /// The workspace row's `SidebarRowState` (`live`, `stale`, `placeholder`, `creating`) and folder line.
    public var rowState: String?
    public var directory: String?
    public var inList: Bool
    public var suppressed: Bool
    /// The row's view stands for the selection now (`fill` says whether it paints).
    public var selected: Bool
    /// The workspace is muted (`notifications.mutedWorkspaces`): its row draws the mark.
    public var muted: Bool
    /// The workspace row's merged status (`StatusIndicatorState`), e.g.
    /// `success` for an unseen done, nil for other rows.
    public var activity: String? = nil
    /// The icon the row's view draws (`symbol`, `swatch`, `emoji`, `favicon`; workspace and
    /// tab rows), nil when it draws none or has no live view, e.g. scrolled off (`SidebarRowView.debugIcon`).
    public var icon: String? = nil
    /// The address of the favicon a link row draws.
    public var iconAddress: String? = nil
    /// A url, tab or app row's document item id and ref kind (`url`, `tab`, `app`, ...), loose or a group's member.
    public var item: String? = nil
    public var itemKind: String? = nil
    /// The view's frame as drawn now (its presentation, mid-animation), and
    /// whether it clips its content (an opening or closing row).
    public var shownFrame: CGRect? = nil
    public var clips: Bool = false
    /// The group the row lists in (its id), nil for a loose row.
    public var group: String? = nil
    /// The row paints a fill now (hover, selection or a drop), its own or a part's.
    public var fill: Bool = false
    /// The pointer is over the row's view now.
    public var hovered: Bool = false
    /// The row's disclosure chevron: the pack icon it draws, its frame in the
    /// row and whether it shows; nil when the row has none.
    public var disclosureIcon: String? = nil
    public var disclosureFrame: CGRect? = nil
    public var disclosureShown: Bool = false
    /// The row's second line as its content draws it (`WorkspaceRowContent.detail`).
    public var detail: String? = nil
    /// The workspace's unread badge (`UnreadState`: `none`, `dot`, `count(n)`), nil for other rows.
    public var unread: String? = nil
    /// The row draws a progress bar (`WorkspaceRowContent.progress`), and the agent-working slot.
    public var progress: Bool = false
    public var showsWorking: Bool = false
    /// The row's view draws the archived look (dimmed, archiving-DESIGN.md).
    public var archived: Bool = false

    /// The row with what its view draws now: its fill, hover and disclosure.
    func drawn(by view: SidebarRowView?) -> SidebarDebugRow {
        var row = self
        let disclosure = view?.debugDisclosure
        row.fill = view?.debugFill == true
        row.hovered = view?.isHovered == true
        row.archived = view?.debugArchived == true
        (row.disclosureIcon, row.disclosureFrame, row.disclosureShown) = (disclosure?.icon, disclosure?.frame, disclosure?.shown == true)
        return row
    }
}

/// One sidebar layout item (a top or bottom region row), for
/// `debug.sidebar_rows`: what it points at, whether it is active, and where
/// its view is (nil while it draws nothing).
public struct SidebarDebugItem: Sendable {
    public var id: String
    public var refKind: String
    public var ref: String
    public var region: String
    /// The section holding the item: its id and title (nil when untitled).
    public var section: String = ""
    public var sectionTitle: String? = nil
    public var isActive: Bool
    /// The item in window points from the top-left (as `debug.mouse` takes them).
    public var windowFrame: CGRect?
}

/// One drop resolution of an internal drag, for `debug.sidebar_rows`.
public struct SidebarDropProbe: Sendable, Equatable {
    /// `top` or `bottom`: the card's leading edge for the drag direction.
    public var edge: String
    /// The edge in list coordinates as drawn, and in the base layout.
    public var displayY: CGFloat
    public var baseY: CGFloat?
    /// The base-layout row under the edge and the edge's share of its height.
    public var row: String?
    public var fraction: CGFloat?
    /// The resolved target, or nil when the drop is refused.
    public var target: String?
    /// The drop look on the sidebar document: `gap` (a list section opens
    /// its gap), `into` (a group header's drop fill), `line` (the band's
    /// insertion line), `refused`; nil off the document.
    public var indicator: String? = nil
    /// The reducer's refusal of a refused drop (`cross_machine`, ...).
    public var refusal: String? = nil
}

extension SidebarViewComponents {
    /// Every layout item of the shown sections and its view, client items at their places (debug).
    public func debugLayoutItems() -> [SidebarDebugItem] {
        let height = window?.contentView?.bounds.height ?? 0
        return model.placingTransientItems(in: model.layout.sections).flatMap { section in
            section.items.map { item -> SidebarDebugItem in
                var frame: CGRect?
                for region in bandRegions + list.blockRegions {
                    guard let view = region.itemView(item.id), view.window != nil, !view.isHiddenOrHasHiddenAncestor else { continue }
                    let inWindow = view.convert(view.bounds, to: nil)
                    frame = CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
                }
                return SidebarDebugItem(id: item.id.rawValue, refKind: item.ref.kind, ref: item.ref.value, region: section.region.rawValue,
                                        section: section.id.rawValue, sectionTitle: section.title,
                                        isActive: model.selectedItem == .topItem(item.id), windowFrame: frame)
            }
        }
    }

    /// Every shown section header of the band and the list blocks: its section id, title and frame in window points
    /// from the top-left (debug.sidebar_rows "sections").
    public func debugSectionHeaders() -> [(id: String, title: String?, frame: CGRect)] {
        let height = window?.contentView?.bounds.height ?? 0
        return model.layout.sections.compactMap { section in
            for region in bandRegions + list.blockRegions {
                guard let view = region.headerViews[section.id], view.window != nil, !view.isHiddenOrHasHiddenAncestor else { continue }
                let inWindow = view.convert(view.bounds, to: nil)
                return (section.id.rawValue, section.title, CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height))
            }
            return nil
        }
    }

    /// Every section of the shown layout with its arrangement fields, so a
    /// proof reads an alignment, spacing or reset edit back.
    public func debugLayoutSections() -> [(id: String, title: String?, align: String, gap: Int?, items: Int)] {
        model.layout.sections.map { ($0.id.rawValue, $0.title, $0.arrangement.align.rawValue, $0.arrangement.gap, $0.items.count) }
    }

    /// Whether a drag is active now (a tile drag hides no list row, so `dragging` can be empty while it runs).
    public func debugDragActive() -> Bool { list.drag != nil }

    /// The new-workspace button (+) in window points from the top-left, so a
    /// proof clicks it (`debug.mouse`); nil while it is hidden.
    public func debugNewButtonFrame() -> CGRect? {
        guard !newButton.isHiddenOrHasHiddenAncestor, newButton.window != nil else { return nil }
        let inWindow = newButton.convert(newButton.bounds, to: nil)
        let height = window?.contentView?.bounds.height ?? 0
        return CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    /// The list's rows and their views, the selection and the drag (debug).
    /// The drag's last drop probe (debug): nil while nothing is dragged.
    public func debugDropProbe() -> SidebarDropProbe? { list.drag?.probe }

    /// Starts (`start` true) or stops the per-display-frame motion samples; stop returns them.
    public func debugMotion(start: Bool) -> [SidebarMotionFrame] {
        guard start else { return list.motionProbe.stop() }
        list.motionProbe.start()
        return []
    }

    public func debugRows() -> (rows: [SidebarDebugRow], selection: [String], dragging: [String]) {
        // One lookup table: a per-row `model.workspace` scan is O(rows²) (seconds at 1,000 rows, a watchdog trip).
        var byID: [WorkspaceID: SidebarWorkspace] = [:]
        for ws in model.sections.flatMap(\.workspaces) where byID[ws.id] == nil { byID[ws.id] = ws }
        let rows = list.displayed.rows.map { row -> SidebarDebugRow in
            let view = list.rowViews[row.key]
            var title: String?
            var muted = false
            var activity: String?
            if case let .workspace(id) = row.key, let workspace = byID[id] {
                title = workspace.title
                muted = workspace.muted
                activity = String(describing: workspace.activity)
            }
            let inWindow = list.convert(list.frame(for: row), to: nil)
            let height = window?.contentView?.bounds.height ?? 0
            let windowFrame = CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
            let debugRow = SidebarDebugRow(key: String(describing: row.key), title: title, frame: list.frame(for: row), windowFrame: windowFrame,
                                   viewFrame: view?.frame, viewAlpha: view?.alphaValue, inList: view?.superview === list,
                                   suppressed: list.suppressed.contains(row.key), selected: view?.isSelected == true, muted: muted,
                                   activity: activity, icon: view?.debugIcon, shownFrame: view?.shownFrame, clips: view?.clipsToBounds == true, group: row.group?.rawValue,
                                   detail: row.content?.detail)
            var drawn = debugRow.drawn(by: view)
            drawn.iconAddress = view?.debugIconAddress
            if case let .item(id) = row.key { (drawn.item, drawn.itemKind) = (id, list.listItems[id]?.ref.kind) }
            if case let .workspace(id) = row.key, let ws = byID[id] { (drawn.unread, drawn.rowState, drawn.directory) = ("\(ws.unread)", "\(ws.rowState)", ws.directory) }
            (drawn.progress, drawn.showsWorking) = (row.content?.progress != nil, row.content?.showsWorking == true)
            return drawn
        }
        let selection = model.orderedSelection.map { byID[$0]?.title ?? $0.rawValue }
        let dragging = list.drag.map { drag in drag.hiddenKeys.map { String(describing: $0) } } ?? []
        return (rows, selection, dragging)
    }

    /// The swipe pages now (debug.sidebar_rows): where each sits and what it draws.
    public func debugPaging() -> [String: String] {
        var info: [String: String] = [:]
        func describe(_ view: NSView?) -> String {
            guard let view else { return "none" }
            let tx = (view.layer?.presentation() ?? view.layer)?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
            return "super=\(view.superview.map { String(describing: type(of: $0)) } ?? "nil") frame=\(view.frame) tx=\(tx) hidden=\(view.isHiddenOrHasHiddenAncestor) alpha=\(view.alphaValue)"
        }
        info["page"] = describe(scrollView)
        if let neighbor = spacePaging.neighbor {
            info["neighbor"] = describe(neighbor.view)
            info["neighbor_rows"] = "\(neighbor.list.displayed.rows.count) views=\(neighbor.list.rowViews.count) frame=\(neighbor.list.frame)"
        }
        info["snapshot"] = describe(spacePaging.snapshotView)
        return info
    }
}
