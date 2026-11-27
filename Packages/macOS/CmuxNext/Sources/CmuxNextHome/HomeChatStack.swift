public import AppKit

/// The Home page's chat column keeps its last few chats made while hidden: a switch back to one
/// shows its page at once instead of making the view again and waiting for its first page (the
/// person, 2026-11-23: "switching chiefs is super slow"). Most recent first; past ``limit`` the
/// oldest is removed. The views fill `column` and follow its size.
@MainActor
public final class HomeChatStack<ID: Equatable, Chat: NSView> {
    /// How many chats stay made, the shown one included. Each hidden one keeps its observations
    /// running, so this stays small.
    public static var limit: Int { 4 }

    private weak var column: NSView?
    private(set) var entries: [(id: ID, chat: Chat)] = []

    public init(column: NSView) {
        self.column = column
    }

    // The isolated deinit of a generic main-actor class crashes the Release optimizer (#23050).
    nonisolated deinit {}

    /// The ids kept, most recent first.
    public var ids: [ID] { entries.map(\.id) }

    /// Shows `id`'s chat: the kept one, else the one `make` makes. The chat shown before is hidden
    /// and kept. `hidden` keeps the new one hidden too (the New Message page covers the column).
    @discardableResult
    public func show(_ id: ID, hidden: Bool = false, make: () -> Chat) -> Chat {
        for entry in entries where entry.id != id { entry.chat.isHidden = true }
        let chat = entries.first { $0.id == id }?.chat ?? make()
        chat.isHidden = hidden
        if let column {
            chat.frame = column.bounds
            chat.autoresizingMask = [.width, .height]
            if chat.superview !== column { column.addSubview(chat) }
        }
        entries.removeAll { $0.id == id || $0.chat === chat }
        entries.insert((id, chat), at: 0)
        if entries.count > Self.limit {
            for entry in entries[Self.limit...] { entry.chat.removeFromSuperview() }
            entries.removeSubrange(Self.limit...)
        }
        return chat
    }

    /// Removes every kept chat whose id `listed` refuses (a conversation that left the list) but
    /// never the one shown (the most recent).
    public func keep(only listed: (ID) -> Bool) {
        let gone = entries.dropFirst().filter { !listed($0.id) }
        for entry in gone { entry.chat.removeFromSuperview() }
        entries.removeAll { entry in gone.contains { $0.chat === entry.chat } }
    }
}
