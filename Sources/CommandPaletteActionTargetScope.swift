/// A dynamically scoped action target used only while a command handler runs.
///
/// Palette handlers intentionally reuse the same model methods as shortcuts
/// and menus. This scope lets those shared methods resolve the immutable action
/// target without mutating the app's visible workspace or panel selection.
enum CommandPaletteActionTargetScope {
    @TaskLocal static var current: CommandPaletteActionTarget?
}
