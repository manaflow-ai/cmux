public import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The Recents section's rows (`SidebarLayoutDocument.recentsSection`, an
/// app section the App supplies): one row per recent agent chat, with
/// the chat's agent mark, drawn like the pinned sections' items.
public final class SidebarRecentsView: NSView {
    /// The contribution of the Recents section in the layout.
    public nonisolated static var contribution: String { SidebarLayoutDocument.recentsContribution }
    /// The section's header.
    public static var title: String { String(localized: "sidebar.recents.title", defaultValue: "Recents", bundle: .module) }
    /// A chat with no prompt yet.
    public static var newChatTitle: String { String(localized: "sidebar.recents.newChat", defaultValue: "New chat", bundle: .module) }

    public struct Row: Hashable, Sendable {
        public var id: String
        public var title: String
        /// The agent's brand mark (`AgentBrandID`), or nil for the generic chat glyph.
        public var brand: String?

        public init(id: String, title: String, brand: String?) {
            self.id = id
            self.title = title
            self.brand = brand
        }
    }

    /// Opens the chat with this id.
    public var onOpen: ((String) -> Void)?
    public private(set) var rows: [Row] = []
    private var views: [String: SidebarItemRowView] = [:]

    public override var isFlipped: Bool { true }

    /// The height of `count` rows.
    public static func height(rows count: Int) -> CGFloat { CGFloat(count) * Metrics.sidebarRowHeight }

    public func update(_ rows: [Row]) {
        guard rows != self.rows else { return }
        self.rows = rows
        let ids = Set(rows.map(\.id))
        for (id, view) in views where !ids.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
        }
        for row in rows {
            let view = views[row.id] ?? makeRow(row.id)
            view.configure(SidebarItemInfo(title: row.title, symbol: "bubble.left", icon: .agentChat, brand: row.brand), style: .builtIn)
        }
        needsLayout = true
    }

    private func makeRow(_ id: String) -> SidebarItemRowView {
        let view = SidebarItemRowView()
        view.onPress = { [weak self] in self?.onOpen?(id) }
        views[id] = view
        addSubview(view)
        return view
    }

    public override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() {
            views[row.id]?.frame = NSRect(x: 0, y: CGFloat(index) * Metrics.sidebarRowHeight, width: bounds.width, height: Metrics.sidebarRowHeight)
        }
    }
}
