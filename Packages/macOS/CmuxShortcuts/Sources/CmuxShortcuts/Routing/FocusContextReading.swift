public import AppKit
public import CmuxSettings

/// The read-only seam through which ``ShortcutRouter`` learns the focus state a
/// keystroke happens in, so the matcher can evaluate each action's `when`
/// clause and the dispatch can gate browser/markdown/sidebar shortcuts.
///
/// ## Why this seam exists
///
/// Resolving "is a browser panel focused", "is a markdown viewer focused", "is
/// the right sidebar focused", and the full ``ShortcutContext`` (command-palette
/// visibility, pane/workspace counts, terminal-find visibility, sidebar mode)
/// reaches deep into the app's `TabManager`/`Workspace`/`BrowserPanel`/
/// `MarkdownPanel`/registered-window state. That state is owned by the
/// workspace/terminal/browser/sidebar slices, not by shortcut routing. The
/// router caches one resolved ``ShortcutEventFocusSnapshot`` per event (the
/// faithful relocation of `AppDelegate.shortcutEventFocusContextCache`) and
/// reads everything else through this protocol.
///
/// The conformer is the app target's focus-context reader (currently the
/// `AppDelegate` extension in `KeyboardShortcutContext.swift`); it builds the
/// snapshot from live AppKit/responder/panel state.
@MainActor
public protocol FocusContextReading: AnyObject {
    /// Resolves the focus snapshot for `event`. The router caches this per event,
    /// so the conformer does not need its own cache. Faithful relocation of the
    /// uncached body of `AppDelegate.shortcutEventFocusContext(_:)`.
    func resolveFocusSnapshot(for event: NSEvent) -> ShortcutEventFocusSnapshot
}

/// The immutable focus snapshot a shortcut event is dispatched against,
/// relocated from the app's `ShortcutEventFocusContext`.
///
/// It carries only what shortcut routing needs: the three focus booleans the
/// `when`-clause atoms read, and the full ``ShortcutContext`` the clause
/// evaluator consumes. It does NOT carry the live `BrowserPanel`/`MarkdownPanel`
/// references the app-side context held, because acting on those panels is the
/// app-side dispatch's job (it re-resolves the panel through the host seam),
/// keeping this value type `Sendable` and free of god-type references.
public struct ShortcutEventFocusSnapshot: Sendable {
    /// Whether a browser panel owns the event's focus.
    public let browserFocused: Bool
    /// Whether a markdown viewer owns the event's focus (only when no browser
    /// panel does).
    public let markdownFocused: Bool
    /// Whether the right sidebar owns the event's focus.
    public let rightSidebarFocused: Bool
    /// The full context the `when`-clause evaluator reads (focus atoms plus the
    /// non-focus keys: command-palette visibility, pane/workspace counts,
    /// terminal-find visibility, sidebar mode).
    public let shortcutContext: ShortcutContext

    /// Creates a focus snapshot.
    public init(
        browserFocused: Bool,
        markdownFocused: Bool,
        rightSidebarFocused: Bool,
        shortcutContext: ShortcutContext
    ) {
        self.browserFocused = browserFocused
        self.markdownFocused = markdownFocused
        self.rightSidebarFocused = rightSidebarFocused
        self.shortcutContext = shortcutContext
    }
}
