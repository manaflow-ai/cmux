/// How the session tree orders its rows (`sidebar.rowOrder`, Leo 2026-10-18): rows hold the places
/// the user gave them and show their agents' state in place, or a row that needs you moves to the
/// top of its list (the priority projection and a notification's move to the top).
public nonisolated enum SidebarRowOrder: String, Hashable, Sendable, CaseIterable {
    case stable
    case attention
}
