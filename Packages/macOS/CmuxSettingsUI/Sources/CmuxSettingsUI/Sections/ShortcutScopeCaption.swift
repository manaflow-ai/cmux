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
    let canvasLayoutKey = ShortcutContextKnownKey.workspaceCanvasLayout.rawValue
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
    case let .key(key) where key == canvasLayoutKey:
        return canvasLayoutCaption()
    case let .and(.key(key), _) where key == canvasLayoutKey:
        // `Canvas: Actual Size` gates on `canvas && !browser && !markdown` so it
        // never collides with the browser/markdown ⌘0 zoom-reset bindings, but
        // its user-facing scope is still simply "the canvas layout".
        return canvasLayoutCaption()
    default:
        // The remaining built-in scope is the terminal-pane predicate used by
        // Rename Tab/Workspace, Send Ctrl-F, and Clear Screen
        // (`!browser && !sidebar`).
        return String(
            localized: "shortcut.when.caption.terminalFocus",
            defaultValue: "Only while a terminal pane is focused"
        )
    }
}

private func canvasLayoutCaption() -> String {
    String(
        localized: "shortcut.when.caption.canvasLayout",
        defaultValue: "Only while the canvas layout is active"
    )
}
