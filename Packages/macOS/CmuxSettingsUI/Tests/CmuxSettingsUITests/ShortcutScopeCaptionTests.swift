import Testing
import CmuxSettings
@testable import CmuxSettingsUI

/// Coverage for the Settings → Keyboard Shortcuts scope caption that labels
/// context-scoped duplicate default shortcuts (issue #5810).
///
/// Several actions intentionally ship the *same* default chord, disambiguated
/// only by focus/layout context — most visibly the zoom family: `⌘=` / `⌘-`
/// across Zoom In/Out (browser) and Markdown Viewer: Zoom In/Out, and `⌘0`
/// across the browser, markdown, and canvas "Actual Size" actions. Each row
/// must state the scope its binding fires in so the list does not read as a raw
/// duplicate-default collision.
@Suite("Keyboard shortcut scope captions")
struct ShortcutScopeCaptionTests {
    // Package tests resolve `String(localized:)` to the `defaultValue` because
    // the app's `Localizable.xcstrings` is not bundled with the package test
    // target, so the English defaults are the source of truth here.
    private let browserCaption = "Only while a browser pane is focused"
    private let filePreviewTextEditorCaption = "Only while a text file preview is focused"
    private let browserOrFilePreviewTextEditorCaption = "Only while a browser pane or text file preview is focused"
    private let markdownCaption = "Only while a markdown preview is focused"
    private let sidebarCaption = "Only while the right sidebar is focused"
    private let terminalCaption = "Only while a terminal pane is focused"
    private let canvasCaption = "Only while the canvas layout is active"

    private var canvasLayoutKey: String { ShortcutContextKnownKey.workspaceCanvasLayout.rawValue }

    @Test func alwaysClauseHasNoCaption() {
        #expect(builtInScopeCaption(for: .always) == nil)
    }

    @Test func focusAtomClausesMapToTheirCaption() {
        #expect(builtInScopeCaption(for: .atom(.sidebarFocus)) == sidebarCaption)
        #expect(builtInScopeCaption(for: .atom(.browserFocus)) == browserCaption)
        #expect(builtInScopeCaption(for: .atom(.filePreviewTextEditorFocus)) == filePreviewTextEditorCaption)
        #expect(builtInScopeCaption(for: .atom(.markdownFocus)) == markdownCaption)
    }

    @Test func browserOrFilePreviewTextEditorClauseMapsToCombinedCaption() {
        let browserFirst = ShortcutWhenClause.or(.atom(.browserFocus), .atom(.filePreviewTextEditorFocus))
        let filePreviewFirst = ShortcutWhenClause.or(.atom(.filePreviewTextEditorFocus), .atom(.browserFocus))

        #expect(builtInScopeCaption(for: browserFirst) == browserOrFilePreviewTextEditorCaption)
        #expect(builtInScopeCaption(for: filePreviewFirst) == browserOrFilePreviewTextEditorCaption)
    }

    @Test func terminalPredicateMapsToTerminalCaption() {
        // Rename Tab/Workspace, Send Ctrl-F, Clear Screen gate on
        // `!browser && !sidebar`.
        let clause = ShortcutWhenClause.and(.not(.atom(.browserFocus)), .not(.atom(.sidebarFocus)))
        #expect(builtInScopeCaption(for: clause) == terminalCaption)
    }

    @Test func canvasLayoutClausesMapToCanvasCaption() {
        // Plain canvas-layout actions (Canvas: Zoom In/Out, Tidy, Align, …).
        #expect(builtInScopeCaption(for: .key(canvasLayoutKey)) == canvasCaption)
        // `Canvas: Actual Size` gates on `canvas && !browser && !markdown` so it
        // never collides with the browser/markdown ⌘0 zoom-reset bindings.
        let compound = ShortcutWhenClause.and(
            .key(canvasLayoutKey),
            .and(.not(.atom(.browserFocus)), .not(.atom(.markdownFocus)))
        )
        #expect(builtInScopeCaption(for: compound) == canvasCaption)
    }

    /// The canvas key must be recognized as a required `&&` conjunct regardless
    /// of which side of the `.and` it sits on, so a future clause structure can't
    /// silently fall back to the terminal caption (the bug this PR fixes).
    @Test func canvasLayoutKeyIsMatchedRegardlessOfConjunctPosition() {
        let rightPlaced = ShortcutWhenClause.and(.not(.atom(.browserFocus)), .key(canvasLayoutKey))
        #expect(builtInScopeCaption(for: rightPlaced) == canvasCaption)

        let nested = ShortcutWhenClause.and(
            .not(.atom(.markdownFocus)),
            .and(.not(.atom(.browserFocus)), .key(canvasLayoutKey))
        )
        #expect(builtInScopeCaption(for: nested) == canvasCaption)

        // A *negated* canvas predicate is not a canvas requirement, so it must
        // not borrow the canvas caption.
        let negated = ShortcutWhenClause.and(.not(.key(canvasLayoutKey)), .not(.atom(.sidebarFocus)))
        #expect(builtInScopeCaption(for: negated) == terminalCaption)
    }

    /// Regression for issue #5810: the ⌘= / ⌘- / ⌘0 zoom shortcuts ship the same
    /// default across browser, markdown, and (for ⌘0) canvas. Each must carry the
    /// caption for its own scope. In particular `canvasZoomReset` must read as the
    /// canvas layout, not be mislabeled "Only while a terminal pane is focused".
    @Test func zoomFamilyActionsCarryTheirOwnScopeCaption() {
        for action in [ShortcutAction.browserZoomIn, .browserZoomOut, .browserZoomReset] {
            #expect(builtInScopeCaption(for: action.defaultFocusWhenClause) == browserOrFilePreviewTextEditorCaption)
        }
        for action in [ShortcutAction.markdownZoomIn, .markdownZoomOut, .markdownZoomReset] {
            #expect(builtInScopeCaption(for: action.defaultFocusWhenClause) == markdownCaption)
        }
        for action in [ShortcutAction.canvasZoomIn, .canvasZoomOut, .canvasZoomReset] {
            #expect(builtInScopeCaption(for: action.defaultFocusWhenClause) == canvasCaption)
        }
        // The specific mislabel this issue fixes: canvas must not fall through to
        // the terminal caption.
        #expect(builtInScopeCaption(for: ShortcutAction.canvasZoomReset.defaultFocusWhenClause) != terminalCaption)
    }

    /// The duplicate default chords are intentional: each pair shares one
    /// keystroke yet has context-disjoint effective clauses, so the runtime and
    /// the recorder let them coexist. That coexistence is exactly why the scope
    /// caption is required to disambiguate them in Settings.
    @Test func zoomDuplicateDefaultsShareAStrokeButCoexist() throws {
        func assertCoexisting(_ lhs: ShortcutAction, _ rhs: ShortcutAction) throws {
            let lhsShortcut = try #require(lhs.defaultShortcut)
            let rhsShortcut = try #require(rhs.defaultShortcut)
            #expect(!lhsShortcut.isUnbound)
            #expect(!rhsShortcut.isUnbound)
            // Same physical keystroke…
            #expect(numberedAwareStrokesConflict(
                lhsShortcut.first, numbered: lhs.usesNumberedDigitMatching,
                rhsShortcut.first, numbered: rhs.usesNumberedDigitMatching
            ))
            // …but context-disjoint, so they are not a real collision.
            #expect(!ShortcutWhenClause.bindingsCollide(
                lhs.defaultFocusWhenClause, lhsHasPriority: lhs.hasPriorityShortcutRouting,
                rhs.defaultFocusWhenClause, rhsHasPriority: rhs.hasPriorityShortcutRouting
            ))
        }
        try assertCoexisting(.browserZoomIn, .markdownZoomIn)        // ⌘=
        try assertCoexisting(.browserZoomOut, .markdownZoomOut)      // ⌘-
        try assertCoexisting(.browserZoomReset, .markdownZoomReset)  // ⌘0
        try assertCoexisting(.browserZoomReset, .canvasZoomReset)    // ⌘0
        try assertCoexisting(.markdownZoomReset, .canvasZoomReset)   // ⌘0
    }
}
