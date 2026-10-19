import CmuxNextSettings

/// The one rule for where a link or path the person opens from a pane lands (``LinkOpener``):
/// a terminal's Cmd-click, a link in an agent chat, Home, a Markdown or code page, a `cmux://`
/// path link. The source pane never loses what it shows:
///
/// - ``LinkPlacement/splitRight`` (default) and ``LinkPlacement/newColumn``: the pane right of
///   the source on its screen gets the new tab, so repeated opens reuse one pane; with no pane
///   there, a new split (or a new column) opens right of the source.
/// - ``LinkPlacement/samePane``: a tab in the source pane, unless the source takes no new tabs
///   (the pinned Home column), which acts as ``LinkPlacement/splitRight``.
///
/// `Pane` is the caller's pane identity (`LayoutPaneID` in the app), so the rule runs without a
/// window or a daemon.
struct LinkOpenPlacement<Pane: Equatable> {
    /// Where the opened item goes.
    enum Target: Equatable {
        /// A new tab in this existing pane.
        case pane(Pane)
        /// A new pane split off the right of this pane.
        case splitRight(of: Pane)
        /// A new column right of this pane's column.
        case newColumn(rightOf: Pane)
    }

    var setting: LinkPlacement

    /// Where an item opened from `source` lands. `takesTabs`: the source's strip takes new tabs;
    /// `right`: the pane right of the source on its screen, if any.
    func target(source: Pane, takesTabs: Bool, right: Pane?) -> Target {
        .pane(source) // the old behavior: a tab over the source
    }
}
