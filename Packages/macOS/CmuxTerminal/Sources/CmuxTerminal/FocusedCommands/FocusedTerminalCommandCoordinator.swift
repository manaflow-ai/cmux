public import AppKit

/// Routes the focused-terminal command surface (find/search, keyboard
/// copy-mode, the Ctrl-F force-stop chord, the text-box input toggle/focus/
/// attach, the keep-scrollback clear, and the text-box hide-escape arm) to
/// whichever panel is currently focused.
///
/// TabManager owns the per-window focus state (`selectedWorkspace`, the focused
/// panel id, the workspace's terminal panels), so it cannot move down into a
/// package. This coordinator takes that resolution as injected `@MainActor`
/// closures and forwards each command through the ``FocusedTerminalCommanding``
/// and ``FocusedTerminalFindFallback`` seams the app-target panels conform to.
/// The bodies are byte-faithful lifts of the former
/// `TabManager.startSearch()`, `searchSelection()`, `findNext()`,
/// `findPrevious()`, `hideFind()`, `toggleFocusedTerminalCopyMode()`,
/// `sendCtrlFToFocusedTerminal()`, `toggleFocusedTerminalTextBox()`,
/// `clearFocusedTerminalKeepingScrollback()`,
/// `focusFocusedTerminalTextBoxInputOrTerminal()`,
/// `attachFileToFocusedTerminalTextBoxInput()`,
/// `consumeFocusedTerminalTextBoxHideEscapeIfArmed(in:)`, and
/// `clearFocusedTerminalTextBoxHideEscapeArm()`: each resolves the focused
/// panel and forwards, with the find commands falling back to the focused
/// browser panel when no terminal is focused.
///
/// `@MainActor` because every command mutates AppKit/terminal state on the main
/// thread, matching the callers (keyboard shortcuts, command palette, View
/// menu, the command socket) — state lives where its callers live. This mirrors
/// `FocusedBrowserController` exactly.
@MainActor
public final class FocusedTerminalCommandCoordinator {
    private let resolveFocusedTerminal: @MainActor () -> (any FocusedTerminalCommanding)?
    private let resolveFocusedBrowser: @MainActor () -> (any FocusedTerminalFindFallback)?
    private let resolveWorkspaceTerminals: @MainActor () -> [any FocusedTerminalCommanding]

    /// Creates a coordinator.
    /// - Parameters:
    ///   - resolveFocusedTerminal: returns the focused terminal panel, if any.
    ///   - resolveFocusedBrowser: returns the focused browser panel, if any.
    ///   - resolveWorkspaceTerminals: returns all terminal panels in the
    ///     selected workspace (used by the text-box hide-escape arm clearing).
    public init(
        resolveFocusedTerminal: @escaping @MainActor () -> (any FocusedTerminalCommanding)?,
        resolveFocusedBrowser: @escaping @MainActor () -> (any FocusedTerminalFindFallback)?,
        resolveWorkspaceTerminals: @escaping @MainActor () -> [any FocusedTerminalCommanding]
    ) {
        self.resolveFocusedTerminal = resolveFocusedTerminal
        self.resolveFocusedBrowser = resolveFocusedBrowser
        self.resolveWorkspaceTerminals = resolveWorkspaceTerminals
    }

    // MARK: - Find / search

    /// Whether a find overlay is visible for the focused terminal or browser.
    public var isFindVisible: Bool {
        resolveFocusedTerminal()?.isSearchVisible == true
            || resolveFocusedBrowser()?.isSearchVisible == true
    }

    /// Whether the focused terminal's selection can seed a find needle.
    public var canUseSelectionForFind: Bool {
        resolveFocusedTerminal()?.hasSelectionForFind == true
    }

    /// Starts or focuses the find overlay. Returns whether the search was handled.
    @discardableResult
    public func startSearch() -> Bool {
        if let panel = resolveFocusedTerminal() {
            return panel.startSearch()
        }
        guard let browserPanel = resolveFocusedBrowser() else { return false }
        browserPanel.startFind()
        return browserPanel.isSearchVisible
    }

    /// Seeds and focuses a search from the focused terminal's selection.
    public func searchSelection() {
        guard let panel = resolveFocusedTerminal() else { return }
        panel.searchSelection()
    }

    /// Advances to the next find match (terminal first, then browser).
    public func findNext() {
        if let panel = resolveFocusedTerminal() {
            panel.findNext()
            return
        }
        resolveFocusedBrowser()?.findNext()
    }

    /// Moves to the previous find match (terminal first, then browser).
    public func findPrevious() {
        if let panel = resolveFocusedTerminal() {
            panel.findPrevious()
            return
        }
        resolveFocusedBrowser()?.findPrevious()
    }

    /// Hides the find overlay (terminal first, then browser).
    public func hideFind() {
        if let panel = resolveFocusedTerminal() {
            panel.hideSearch()
            return
        }
        resolveFocusedBrowser()?.hideFind()
    }

    // MARK: - Copy mode / chords

    /// Toggles the focused terminal's keyboard copy-mode. Returns `false` if no
    /// terminal is focused.
    @discardableResult
    public func toggleFocusedTerminalCopyMode() -> Bool {
        guard let panel = resolveFocusedTerminal() else { return false }
        return panel.toggleKeyboardCopyMode()
    }

    /// Forwards a single Ctrl-F (`^F`) key press to the focused terminal surface,
    /// faithfully encoded through Ghostty so it matches whatever the running TUI
    /// would receive from a real keystroke.
    ///
    /// This is the non-keyboard escape hatch for control chords that a focused TUI
    /// reads off the raw tty. The motivating case is Claude Code's force-stop, which
    /// is only exposed as "press Ctrl-F twice"; invoke this action twice to deliver
    /// it. Delivery bypasses cmux's shortcut/menu/responder layers entirely.
    ///
    /// - Returns: `true` when the chord was sent or queued for the focused terminal,
    ///   `false` when no terminal panel is focused.
    @discardableResult
    public func sendCtrlFToFocusedTerminal() -> Bool {
        guard let panel = resolveFocusedTerminal() else { return false }
        return panel.sendCtrlF()
    }

    // MARK: - Text box

    /// Toggles the focused terminal's text-box input. Returns `false` if no
    /// terminal is focused.
    @discardableResult
    public func toggleFocusedTerminalTextBox() -> Bool {
        guard let panel = resolveFocusedTerminal() else { return false }
        return panel.toggleTextBoxInput()
    }

    /// Clears the focused terminal's visible screen while preserving scrollback.
    ///
    /// The shared model path behind the Cmd+Shift+K shortcut and the
    /// "Clear Screen (Keep Scrollback)" command palette entry.
    ///
    /// - Returns: `true` when a focused terminal performed the clear, `false` when
    ///   no terminal panel is focused.
    @discardableResult
    public func clearFocusedTerminalKeepingScrollback() -> Bool {
        guard let panel = resolveFocusedTerminal() else { return false }
        return panel.clearScreenKeepingScrollbackAndRefresh()
    }

    /// Focuses the focused terminal's text-box input, or the terminal itself.
    /// Returns `false` if no terminal is focused.
    @discardableResult
    public func focusFocusedTerminalTextBoxInputOrTerminal() -> Bool {
        guard let panel = resolveFocusedTerminal() else { return false }
        return panel.focusTextBoxInputOrTerminal()
    }

    /// Attaches a file to the focused terminal's text-box input. Returns `false`
    /// if no terminal is focused.
    @discardableResult
    public func attachFileToFocusedTerminalTextBoxInput() -> Bool {
        guard let panel = resolveFocusedTerminal() else { return false }
        return panel.attachFileToTextBoxInput()
    }

    /// Consumes the text-box hide-escape arm for the focused terminal if it is
    /// armed for the given window, clearing every other workspace terminal's arm
    /// when nothing was consumed.
    ///
    /// - Returns: `true` when the focused terminal consumed the escape; `false`
    ///   otherwise (including when no terminal is focused, in which case every
    ///   arm is cleared).
    @discardableResult
    public func consumeFocusedTerminalTextBoxHideEscapeIfArmed(in window: NSWindow?) -> Bool {
        guard let focusedPanel = resolveFocusedTerminal() else {
            clearFocusedTerminalTextBoxHideEscapeArm()
            return false
        }
        let consumed = focusedPanel.consumeTextBoxHideEscapeIfArmed(in: window)
        guard !consumed else { return true }
        for panel in resolveWorkspaceTerminals() {
            if panel === focusedPanel { continue }
            panel.clearTextBoxHideEscapeArm()
        }
        return false
    }

    /// Clears the text-box hide-escape arm for every terminal in the selected
    /// workspace.
    public func clearFocusedTerminalTextBoxHideEscapeArm() {
        for panel in resolveWorkspaceTerminals() {
            panel.clearTextBoxHideEscapeArm()
        }
    }
}
