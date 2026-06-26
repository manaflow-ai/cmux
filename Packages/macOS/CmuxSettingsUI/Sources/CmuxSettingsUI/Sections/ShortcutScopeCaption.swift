import CmuxSettings
import Foundation

/// A localized caption describing the focus/layout scope a context-limited
/// shortcut fires in, derived from its built-in ``ShortcutWhenClause``.
///
/// Returns `nil` for always-on shortcuts so unscoped rows stay uncluttered.
///
/// This drives the Settings → Keyboard Shortcuts scope caption so context-scoped
/// duplicate defaults are explicitly indicated instead of reading as a plain
/// conflict (issue #5810). Several actions intentionally ship the *same* chord,
/// disambiguated only by focus/layout context:
///
/// - `⌘=` / `⌘-` — **Zoom In/Out** (browser) and **Markdown Viewer: Zoom In/Out**
/// - `⌘0` — **Actual Size** across the browser, the markdown viewer, and the
///   canvas (`Canvas: Actual Size`)
/// - `⌘R` / `⌘⇧R` — **Reload Page** (browser) and **Rename Tab / Rename Workspace**
///
/// Each row therefore carries a caption stating when its binding is live, which
/// is what keeps these from looking like duplicate-default collisions.
///
/// The mapping mirrors ``ShortcutAction/defaultFocusWhenClause``: keep the two in
/// sync when a new built-in focus context is introduced.
func builtInScopeCaption(for clause: ShortcutWhenClause) -> String? {
    switch clause {
    case .always:
        return nil
    case .atom(.sidebarFocus):
        return String(
            localized: "shortcut.when.caption.sidebarFocus",
            defaultValue: "Only while the right sidebar is focused"
        )
    case .atom(.browserFocus):
        return String(
            localized: "shortcut.when.caption.browserFocus",
            defaultValue: "Only while a browser pane is focused"
        )
    case .atom(.markdownFocus):
        return String(
            localized: "shortcut.when.caption.markdownFocus",
            defaultValue: "Only while a markdown preview is focused"
        )
    default:
        return String(
            localized: "shortcut.when.caption.terminalFocus",
            defaultValue: "Only while a terminal pane is focused"
        )
    }
}
