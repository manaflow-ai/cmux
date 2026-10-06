import Foundation

// New chat and Search Chats lead the top section, as the ChatGPT desktop
// app's sidebar opens with them. A stored layout equal to a default from
// before them gains both through ordinary ops; a layout the user changed
// keeps its items.
extension SidebarLayoutDocument {
    public nonisolated static let newChatItemID = LayoutItemID("itm_new_chat")
    public nonisolated static let searchChatsItemID = LayoutItemID("itm_search_chats")

    /// New chat, then Search Chats.
    public nonisolated static let chatItems = [
        LayoutItem(id: newChatItemID, ref: .builtIn(.newAgentChat)),
        LayoutItem(id: searchChatsItemID, ref: .builtIn(.searchChats)),
    ]

    /// The defaults (with or without CodeRouter on top) as they were before
    /// Recents (`recents: false`) and before the chat items
    /// (`chatItems: false`), only to recognize them.
    nonisolated static func earlierDefaults(recents: Bool, chatItems: Bool) -> [[LayoutSection]] {
        [defaults, migrationTarget].map { document in
            var sections = document.sections
            if !recents { sections.removeAll { $0.id == recentsSectionID } }
            if !chatItems {
                let ids = Set(Self.chatItems.map(\.id))
                for s in sections.indices { sections[s].items.removeAll { ids.contains($0.id) } }
            }
            return sections
        }
    }

    /// Adds New chat and Search Chats to the top of a layout that equals a
    /// default from before them, with or without Recents, or none.
    public nonisolated var chatItemsMigrationOps: [SidebarLayoutOp] {
        guard Self.chatItems.allSatisfy({ item($0.id) == nil }) else { return [] }
        let earlier = Self.earlierDefaults(recents: true, chatItems: false) + Self.earlierDefaults(recents: false, chatItems: false)
        guard earlier.contains(sections) else { return [] }
        return Self.chatItems.enumerated().map { .itemAdd($0.element, section: Self.topSectionID, index: $0.offset) }
    }
}
