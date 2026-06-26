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
    case let other where clauseRequiresKey(other, key: canvasLayoutKey):
        // Any clause that *requires* the canvas-layout key is scoped to the
        // canvas layout — both the plain `Canvas: …` actions (`canvas`) and
        // `Canvas: Actual Size`, whose `canvas && !browser && !markdown` clause
        // keeps its ⌘0 default off the browser/markdown zoom-reset bindings.
        // Matching the key as a required conjunct (rather than positionally)
        // avoids re-introducing the very mislabel this caption fixes if a future
        // clause places the canvas predicate on the other side of an `&&`.
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

/// Whether `clause` requires `key` to be true — i.e. a bare `.key(key)` term
/// appears as a top-level conjunct (`&&`), at any `.and` nesting depth.
///
/// Negated (`.not`) or alternative (`.or`) occurrences do not count as a
/// requirement, so `!canvas` predicates are correctly excluded.
private func clauseRequiresKey(_ clause: ShortcutWhenClause, key: String) -> Bool {
    switch clause {
    case let .key(name):
        return name == key
    case let .and(lhs, rhs):
        return clauseRequiresKey(lhs, key: key) || clauseRequiresKey(rhs, key: key)
    default:
        return false
    }
}

private func canvasLayoutCaption() -> String {
    String(
        localized: "shortcut.when.caption.canvasLayout",
        defaultValue: "Only while the canvas layout is active"
    )
}
