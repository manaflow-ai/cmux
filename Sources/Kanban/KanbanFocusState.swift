import SwiftUI

/// Per-window keyboard-focus tracking for the kanban board (Stage 5 board
/// navigation). Tracks which card is "focused" for arrow-key navigation and
/// the Return/⌥⌃←/⌥⌃→/⌥⌫ mutation shortcuts, independent of the AppKit first
/// responder — the board has no per-card focusable views, so this is a
/// dedicated logical-focus cursor instead.
///
/// Injected exactly like `SidebarSelectionState`: created once per window in
/// `AppDelegate`, held on `MainWindowContext` for shortcut dispatch, and
/// `.environmentObject`-injected at the `ContentView` root so `KanbanBoardView`
/// can read/write it.
@MainActor
final class KanbanFocusState: ObservableObject {
    /// The workspace id of the currently keyboard-focused card, or `nil` when
    /// nothing is focused (e.g. the board has no cards yet).
    @Published var focusedCardId: UUID?

    /// `nonisolated` so it can be used as a default argument value
    /// (`kanbanFocusState: KanbanFocusState = KanbanFocusState()`) in
    /// `MainWindowContext.init` / `registerMainWindow`, which are called from
    /// nonisolated contexts. Initializing the `nil` default needs no isolation.
    nonisolated init() {}
}
