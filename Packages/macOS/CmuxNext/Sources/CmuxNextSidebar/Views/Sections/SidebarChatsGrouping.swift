/// The grouping choices shown by the All chats sidebar section. `newest` is
/// one flat list, newest first (the default, Lawrence 2026-10-09).
public nonisolated enum SidebarChatsGrouping: String, CaseIterable, Hashable, Sendable {
    case newest
    case harness
    case folder
    case account
}
