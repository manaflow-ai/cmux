public import AppKit

/// One drawn All chats row, for `debug.sidebar_rows`: the chat, its harness mark, and where it is.
public struct SidebarDebugChatRow: Sendable {
    public var id: String
    public var title: String
    public var harness: String
    public var brand: String?
    /// The row draws its leading mark (cx-tr0w).
    public var iconShown: Bool
    /// The row in window points from the top-left (as `debug.mouse` takes them).
    public var windowFrame: CGRect
}

/// All chats as drawn, for `debug.sidebar_rows`: open or minimized, its header (a click opens
/// it) and the rows the list draws now.
public struct SidebarDebugChats: Sendable {
    public var expanded: Bool
    public var headerFrame: CGRect
    public var rows: [SidebarDebugChatRow]
}

extension SidebarChatsView {
    /// The section as drawn now (debug).
    public func debugChats() -> SidebarDebugChats {
        let height = window?.contentView?.bounds.height ?? 0
        func inWindow(_ view: NSView) -> CGRect {
            let rect = view.convert(view.bounds, to: nil)
            return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        let visible = chatTable.rows(in: chatTable.visibleRect)
        let rows = (visible.lowerBound..<visible.upperBound).compactMap { index -> SidebarDebugChatRow? in
            guard let view = chatTable.view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarChatRowView,
                  let row = view.row, !view.isHiddenOrHasHiddenAncestor else { return nil }
            return SidebarDebugChatRow(id: row.id, title: row.title, harness: row.harness, brand: row.brand,
                                       iconShown: !view.icon.isHidden && view.icon.image != nil, windowFrame: inWindow(view))
        }
        return SidebarDebugChats(expanded: isExpanded, headerFrame: inWindow(header), rows: rows)
    }
}
