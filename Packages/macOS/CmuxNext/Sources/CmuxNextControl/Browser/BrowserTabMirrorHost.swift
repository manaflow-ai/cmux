/// Shows one app browser tab in a second pane as well (`browser.page.mirror`).
///
/// A mirror is not a copy: the tab keeps one page and one renderer, keyed by
/// its tab id. The mirror is a chip in the other pane's strip that names the
/// same tab; the pane that shows it takes the live page view (the app's
/// surface ledger reparents it, as a tab moved between panes), and the tab's
/// own pane takes it back when it shows the tab again. So an agent's tab in
/// its own workspace can show live in Home's right column, with its agent
/// cursor, without a second page (plans/cmux-next/shared-browser-tabs.md).
///
/// The app implements it on the main actor (its strips and selections live there); tests pass a recording fake.
public protocol BrowserTabMirrorHost: Sendable {
    /// Lists `tab` in `pane`'s strip too, selected when `select`.
    ///
    /// - Parameters:
    ///   - tab: the public id of a browser tab in another pane.
    ///   - pane: the pane id the mirror goes to.
    ///   - select: show the mirror now (false while the person works in that pane).
    /// - Returns: false when the app has no such pane.
    @MainActor func mirror(tab: String, into pane: String, select: Bool) async -> Bool

    /// Takes `tab`'s mirror out of `pane`, or out of every pane when `pane` is nil.
    ///
    /// - Returns: the panes it left, sorted.
    @MainActor func unmirror(tab: String, from pane: String?) async -> [String]
}
