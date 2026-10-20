/// What an inline-rename field-editor keystroke means. Pure and UI-free so it
/// can be unit-tested without launching the app.
enum SidebarInlineRenameAction: Equatable {
    case commit
    case caretToStart
    case cancel
    case passThrough
}
