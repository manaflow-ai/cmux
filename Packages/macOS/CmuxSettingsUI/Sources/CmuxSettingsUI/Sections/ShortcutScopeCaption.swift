import CmuxSettings
import Foundation

/// Resolves localized captions for built-in keyboard shortcut focus scopes.
struct ShortcutScopeCaptionResolver {
    /// Returns a caption for the built-in focus/layout scope represented by `clause`.
    func caption(for clause: ShortcutWhenClause) -> String? {
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
        case .atom(.filePreviewTextEditorFocus):
            return String(
                localized: "shortcut.when.caption.filePreviewTextEditorFocus",
                defaultValue: "Only while a text file preview is focused"
            )
        case .or(.atom(.browserFocus), .atom(.filePreviewTextEditorFocus)),
             .or(.atom(.filePreviewTextEditorFocus), .atom(.browserFocus)):
            return String(
                localized: "shortcut.when.caption.browserOrFilePreviewTextEditorFocus",
                defaultValue: "Only while a browser pane or text file preview is focused"
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

    /// Whether `clause` requires `key` to be true as a top-level `&&` conjunct.
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
}
