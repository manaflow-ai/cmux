import CCmuxLayoutReducerFFI
import CoreGraphics

/// A snapshot as `cmux_agent_cursor_visibility` reads it: every id numbered
/// for the call (the rules compare ids only for identity), and windows,
/// listed workspaces, sidebar rows, panes and chips as flat arrays with
/// (offset, count) ranges. FFI glue: no rule here. `load` refills the same
/// storage, so a kept snapshot allocates nothing once its arrays are big enough.
nonisolated struct AgentCursorVisibilityFlatSnapshot {
    /// `CMUX_FOCUS_NONE` (`UINT32_MAX`, which Swift does not import as a constant).
    static let none = UInt32.max

    private var numbers: [String: UInt32] = [:]
    private var names: [String] = []
    private var windows: [CmuxCursorWindow] = []
    private var ids: [UInt32] = []
    private var rows: [CmuxCursorKeyedRect] = []
    private var panes: [CmuxCursorPane] = []
    private var chips: [CmuxCursorKeyedRect] = []
    private var target: UInt32 = 0
    private var tabWorkspace = Self.none
    private var tabPane = Self.none

    /// Replaces the contents with `snapshot` for target `id`, keeping the storage.
    mutating func load(target id: String, snapshot: AgentCursorVisibilitySnapshot) {
        numbers.removeAll(keepingCapacity: true)
        names.removeAll(keepingCapacity: true)
        windows.removeAll(keepingCapacity: true)
        ids.removeAll(keepingCapacity: true)
        rows.removeAll(keepingCapacity: true)
        panes.removeAll(keepingCapacity: true)
        chips.removeAll(keepingCapacity: true)
        target = number(id)
        (tabWorkspace, tabPane) = (Self.none, Self.none)
        if let tab = snapshot.tab {
            tabWorkspace = number(tab.workspace)
            tabPane = number(tab.pane)
        }
        for window in snapshot.windows { add(window) }
    }

    /// Runs `body` with the C snapshot; its pointers live only for the call.
    func withSnapshot<R>(_ body: (UnsafePointer<CmuxCursorSnapshot>) -> R) -> R {
        let (target, tabWorkspace, tabPane) = (target, tabWorkspace, tabPane)
        return windows.withUnsafeBufferPointer { windows in
            ids.withUnsafeBufferPointer { ids in
                rows.withUnsafeBufferPointer { rows in
                    panes.withUnsafeBufferPointer { panes in
                        chips.withUnsafeBufferPointer { chips in
                            var snapshot = CmuxCursorSnapshot(
                                target: target, tab_workspace: tabWorkspace, tab_pane: tabPane, reserved: 0,
                                windows: windows.baseAddress, windows_count: windows.count,
                                ids: ids.baseAddress, ids_count: ids.count,
                                rows: rows.baseAddress, rows_count: rows.count,
                                panes: panes.baseAddress, panes_count: panes.count,
                                chips: chips.baseAddress, chips_count: chips.count)
                            return withUnsafePointer(to: &snapshot, body)
                        }
                    }
                }
            }
        }
    }

    /// The typed answer as the app's value; nil for a number the header does not list.
    func visibility(_ answer: CmuxCursorVisibility) -> AgentCursorVisibility? {
        switch answer.kind {
        case CMUX_CURSOR_VISIBLE:
            guard let window = name(answer.window) else { return nil }
            return .visible(window: window, viewport: Self.cgRect(answer.viewport), clip: Self.cgRect(answer.clip),
                            zoom: answer.zoom, scale: answer.scale)
        case CMUX_CURSOR_HIDDEN:
            guard let window = name(answer.window), let anchor = AgentCursorAnchor(ffiNumber: answer.anchor) else { return nil }
            return .hidden(window: window, anchor: anchor, rect: Self.cgRect(answer.rect))
        case CMUX_CURSOR_NOT_DRAWN:
            return AgentCursorNotDrawnReason(ffiNumber: answer.reason).map { .notDrawn($0) }
        default:
            return nil
        }
    }

    private mutating func number(_ id: String) -> UInt32 {
        if let number = numbers[id] { return number }
        let number = UInt32(names.count)
        numbers[id] = number
        names.append(id)
        return number
    }

    /// `id`'s number, or `none` for no id.
    private mutating func optionalNumber(_ id: String?) -> UInt32 {
        guard let id else { return Self.none }
        return number(id)
    }

    private func name(_ number: UInt32) -> String? {
        let index = Int(number)
        return names.indices.contains(index) ? names[index] : nil
    }

    /// `rect` keyed by `key`'s number.
    private mutating func keyed(_ key: String, _ rect: AgentCursorRect) -> CmuxCursorKeyedRect {
        CmuxCursorKeyedRect(key: number(key), reserved: 0, rect: Self.rect(rect))
    }

    private mutating func add(_ window: AgentCursorVisibilitySnapshot.Window) {
        let listedOffset = UInt32(ids.count)
        for workspace in window.listedWorkspaces {
            let listed = number(workspace)
            ids.append(listed)
        }
        let rowsOffset = UInt32(rows.count)
        for (key, rect) in window.sidebarRows {
            let row = keyed(key, rect)
            rows.append(row)
        }
        let rowsCount = UInt32(rows.count) - rowsOffset
        let panesOffset = UInt32(panes.count)
        for pane in window.panes { add(pane) }
        var flags: UInt32 = 0
        if window.minimized { flags |= CMUX_CURSOR_WINDOW_MINIMIZED }
        if window.onActiveSpace { flags |= CMUX_CURSOR_WINDOW_ON_ACTIVE_SPACE }
        if window.sidebarHidden { flags |= CMUX_CURSOR_WINDOW_SIDEBAR_HIDDEN }
        let id = number(window.id)
        let shown = optionalNumber(window.shownWorkspace)
        windows.append(CmuxCursorWindow(
            id: id, shown_workspace: shown, flags: flags,
            listed_offset: listedOffset, listed_count: UInt32(window.listedWorkspaces.count),
            rows_offset: rowsOffset, rows_count: rowsCount,
            panes_offset: panesOffset, panes_count: UInt32(window.panes.count), reserved: 0,
            overlay: Self.rect(window.overlay)))
    }

    private mutating func add(_ pane: AgentCursorVisibilitySnapshot.Pane) {
        let chipsOffset = UInt32(chips.count)
        for (key, rect) in pane.chips {
            let chip = keyed(key, rect)
            chips.append(chip)
        }
        let chipsCount = UInt32(chips.count) - chipsOffset
        var flags: UInt32 = 0
        func take(_ rect: AgentCursorRect?, _ bit: UInt32) -> CmuxCursorRect {
            guard let rect else { return CmuxCursorRect() }
            flags |= bit
            return Self.rect(rect)
        }
        let frame = take(pane.frame, CMUX_CURSOR_PANE_HAS_FRAME)
        let clip = take(pane.clip, CMUX_CURSOR_PANE_HAS_CLIP)
        let strip = take(pane.strip, CMUX_CURSOR_PANE_HAS_STRIP)
        let viewport = take(pane.page?.viewport, CMUX_CURSOR_PANE_HAS_PAGE)
        if pane.page?.scale != nil { flags |= CMUX_CURSOR_PANE_HAS_SCALE }
        let id = number(pane.id)
        let selected = optionalNumber(pane.selectedTab)
        panes.append(CmuxCursorPane(
            id: id, selected_tab: selected, flags: flags,
            chips_offset: chipsOffset, chips_count: chipsCount, reserved: 0,
            frame: frame, clip: clip, strip: strip, viewport: viewport,
            zoom: pane.page?.zoom ?? 0, scale: pane.page?.scale ?? 0))
    }

    private static func rect(_ rect: AgentCursorRect) -> CmuxCursorRect {
        CmuxCursorRect(x: rect.x, y: rect.y, w: rect.w, h: rect.h)
    }

    private static func cgRect(_ rect: CmuxCursorRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
    }
}

/// The header's anchor and reason numbers (`CMUX_CURSOR_ANCHOR_*`,
/// `CMUX_CURSOR_REASON_*`); a test checks every case against them.
nonisolated extension AgentCursorAnchor {
    init?(ffiNumber: UInt32) {
        switch ffiNumber {
        case CMUX_CURSOR_ANCHOR_TAB_CHIP: self = .tabChip
        case CMUX_CURSOR_ANCHOR_TAB_STRIP: self = .tabStrip
        case CMUX_CURSOR_ANCHOR_COLUMN_EDGE_LEADING: self = .columnEdge(.leading)
        case CMUX_CURSOR_ANCHOR_COLUMN_EDGE_TRAILING: self = .columnEdge(.trailing)
        case CMUX_CURSOR_ANCHOR_COLUMN_EDGE_TOP: self = .columnEdge(.top)
        case CMUX_CURSOR_ANCHOR_COLUMN_EDGE_BOTTOM: self = .columnEdge(.bottom)
        case CMUX_CURSOR_ANCHOR_WORKSPACE_ROW: self = .workspaceRow
        case CMUX_CURSOR_ANCHOR_WINDOW_EDGE: self = .windowEdge
        default: return nil
        }
    }

    var ffiNumber: UInt32 {
        switch self {
        case .tabChip: CMUX_CURSOR_ANCHOR_TAB_CHIP
        case .tabStrip: CMUX_CURSOR_ANCHOR_TAB_STRIP
        case .columnEdge(.leading): CMUX_CURSOR_ANCHOR_COLUMN_EDGE_LEADING
        case .columnEdge(.trailing): CMUX_CURSOR_ANCHOR_COLUMN_EDGE_TRAILING
        case .columnEdge(.top): CMUX_CURSOR_ANCHOR_COLUMN_EDGE_TOP
        case .columnEdge(.bottom): CMUX_CURSOR_ANCHOR_COLUMN_EDGE_BOTTOM
        case .workspaceRow: CMUX_CURSOR_ANCHOR_WORKSPACE_ROW
        case .windowEdge: CMUX_CURSOR_ANCHOR_WINDOW_EDGE
        }
    }
}

nonisolated extension AgentCursorNotDrawnReason {
    init?(ffiNumber: UInt32) {
        switch ffiNumber {
        case CMUX_CURSOR_REASON_TAB_CLOSED: self = .tabClosed
        case CMUX_CURSOR_REASON_NOT_IN_ANY_WINDOW: self = .notInAnyWindow
        case CMUX_CURSOR_REASON_MINIMIZED: self = .minimized
        case CMUX_CURSOR_REASON_OTHER_SPACE: self = .otherSpace
        default: return nil
        }
    }

    var ffiNumber: UInt32 {
        switch self {
        case .tabClosed: CMUX_CURSOR_REASON_TAB_CLOSED
        case .notInAnyWindow: CMUX_CURSOR_REASON_NOT_IN_ANY_WINDOW
        case .minimized: CMUX_CURSOR_REASON_MINIMIZED
        case .otherSpace: CMUX_CURSOR_REASON_OTHER_SPACE
        }
    }
}
