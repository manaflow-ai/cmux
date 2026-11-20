import AppKit

/// The diff viewer's text size actions (user 2026-11-19: "cmd + and - need to work in diff viewer"): Cmd-= and
/// Cmd-Shift-= (Zoom In), Cmd-- (Zoom Out) and Cmd-0 (Actual Size) while a diff tab has the keyboard
/// (`diffViewerFocused`), as the Markdown viewer's and the code editor's keys are.
///
/// Their rows live in the Rust catalog (cmux-tui/crates/cmux-action-catalog, `browser.rs`). Until the pinned app FFI
/// release carries them (docs/ci/app-ffi-release.md), ``seed(into:)`` adds the same rows to the registry, and
/// ``withAlias(_:)`` adds Cmd-Shift-=; both do nothing once the pinned catalog has them, so the re-pin needs no
/// Swift change.
struct DiffViewerZoomRows {
    nonisolated static let zoomIn: ActionID = "diffViewerZoomIn"
    static let zoomOut: ActionID = "diffViewerZoomOut"
    static let zoomReset: ActionID = "diffViewerZoomReset"

    /// The three rows as the Rust catalog declares them.
    static var descriptors: [ActionDescriptor] {
        func row(_ id: ActionID, _ title: String, _ key: String, _ keywords: [String], _ symbol: String, _ cli: String) -> ActionDescriptor {
            ActionDescriptor(id: id, title: title, keywords: keywords, defaultShortcut: Shortcut(key, modifiers: .command),
                             category: .browser, symbol: symbol, surfaces: [.palette, .keyboard], requires: .diffViewerFocused,
                             targets: [.pane], cliName: cli)
        }
        return [
            row(zoomIn, String(localized: "action.diffViewerZoomIn", defaultValue: "Diff: Zoom In", table: "ActionCatalog", bundle: .localizedModule),
                "=", ["diff", "zoom"], "plus.magnifyingglass", "browser diff-zoom-in"),
            row(zoomOut, String(localized: "action.diffViewerZoomOut", defaultValue: "Diff: Zoom Out", table: "ActionCatalog", bundle: .localizedModule),
                "-", ["diff", "zoom"], "minus.magnifyingglass", "browser diff-zoom-out"),
            row(zoomReset, String(localized: "action.diffViewerZoomReset", defaultValue: "Diff: Actual Size", table: "ActionCatalog",
                                  bundle: .localizedModule),
                "0", ["diff", "zoom", "reset"], "1.magnifyingglass", "browser diff-actual-size"),
        ]
    }

    /// Adds the rows `registry`'s catalog lacks (an app built against a pin that predates them).
    static func seed(into registry: ActionRegistry) {
        let missing = descriptors.filter { registry.descriptor(for: $0.id) == nil }
        if !missing.isEmpty { registry.seed(missing) }
    }

    /// `aliases` with the diff viewer's Cmd-Shift-= Zoom In, unless the pinned catalog already lists it.
    nonisolated static func withAlias(_ aliases: [KeyBinding]) -> [KeyBinding] {
        guard !aliases.contains(where: { $0.command == zoomIn }) else { return aliases }
        return aliases + [KeyBinding(keys: [Shortcut("=", modifiers: [.command, .shift])], command: zoomIn,
                                     when: .has("diffViewerFocused"))]
    }
}
