public import AppKit

/// The per-panel terminal actions the app target drives against the focused
/// terminal panel: find/search, keyboard copy-mode, the Ctrl-F force-stop chord,
/// the text-box input toggle/focus/attach, the keep-scrollback clear, and the
/// text-box hide-escape arm.
///
/// This is the inversion seam for the focused-terminal command surface. The
/// concrete terminal panel lives in the app target (it owns the AppKit hosted
/// view, the panel-level `searchState`, and the focus-intent plumbing), so a
/// lower package cannot import it. Instead the panel conforms to this protocol
/// and ``FocusedTerminalCommandCoordinator`` forwards each command through it,
/// after the app-side composition root resolves which panel is focused.
///
/// Each method is a byte-faithful lift of the corresponding former
/// `TabManager` focused-terminal command body: the panel-side detail
/// (notification posts, focus intent, the `forceRefresh` on success, the DEBUG
/// trace) stays in the app conformance because it touches app-target
/// notification names and the hosted view; the coordinator owns only the
/// terminal-first / browser-fallback routing.
///
/// `@MainActor` because every action mutates AppKit/terminal state on the main
/// thread; the protocol exists where its callers live.
@MainActor
public protocol FocusedTerminalCommanding: AnyObject {
    /// Whether this terminal panel currently has a find/search overlay visible.
    var isSearchVisible: Bool { get }

    /// Whether the terminal currently has a text selection usable as a find needle.
    var hasSelectionForFind: Bool { get }

    /// Starts or focuses the find overlay for this terminal. Returns whether the
    /// search was handled.
    @discardableResult
    func startSearch() -> Bool

    /// Seeds and focuses a search from the current terminal selection.
    func searchSelection()

    /// Advances to the next search match.
    func findNext()

    /// Moves to the previous search match.
    func findPrevious()

    /// Hides the find overlay for this terminal.
    func hideSearch()

    /// Toggles the terminal's keyboard copy-mode. Returns whether it toggled.
    @discardableResult
    func toggleKeyboardCopyMode() -> Bool

    /// Sends a single Ctrl-F (`^F`) chord to the terminal, refreshing on send.
    /// Returns whether the chord was accepted (sent or queued).
    @discardableResult
    func sendCtrlF() -> Bool

    /// Toggles the panel's text-box input. Returns whether it toggled.
    @discardableResult
    func toggleTextBoxInput() -> Bool

    /// Clears the visible screen while preserving scrollback, refreshing on
    /// success. Returns whether a clear was performed.
    @discardableResult
    func clearScreenKeepingScrollbackAndRefresh() -> Bool

    /// Focuses the panel's text-box input, or the terminal if the box is hidden.
    /// Returns whether focus was moved.
    @discardableResult
    func focusTextBoxInputOrTerminal() -> Bool

    /// Opens the file picker to attach a file to the panel's text-box input.
    /// Returns whether the attach flow started.
    @discardableResult
    func attachFileToTextBoxInput() -> Bool

    /// Consumes the text-box hide-escape arm if it is armed for the given window.
    /// Returns whether the escape was consumed.
    @discardableResult
    func consumeTextBoxHideEscapeIfArmed(in window: NSWindow?) -> Bool

    /// Clears the text-box hide-escape arm for this panel.
    func clearTextBoxHideEscapeArm()
}
