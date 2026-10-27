/// What a native push (a script the host runs in a page, ``PageWebView/evaluate(_:whileFrozen:)``)
/// does while its page is frozen (plans/cmux-next/chrome-parity/p13-webui.md 3.C, MQ12): a frozen
/// page runs nothing, so a push either waits for the thaw or thaws the page first.
///
/// Chrome's WebUI never pushes to a page that cannot take it: its message handlers stop pushing in
/// `OnJavascriptDisallowed` and push the current state again in `OnJavascriptAllowed`
/// (content/public/browser/web_ui_message_handler.h). A held push is that current state, sent once.
///
/// ```swift
/// page.evaluate(theme.applyScript, whileFrozen: .latest(.theme))   // waits; only the newest runs
/// page.evaluate(command, whileFrozen: .thawsFirst)                 // the person asked: thaw, then run
/// ```
public nonisolated enum PageFrozenPush: Hashable, Sendable {
    /// The whole state of one kind (the theme, the zoom token, the route): held while the page is
    /// frozen, and on thaw only the latest of each kind runs, in the order those latest ones were sent.
    case latest(PagePushKind)
    /// A call the person or a command made: the page thaws in this turn (it may stay hidden), then
    /// the script runs, after the held ones.
    case thawsFirst
}

/// The kind of a held push (``PageFrozenPush/latest(_:)``): a newer push of one kind replaces the
/// older one. A module adds its own kinds as static members.
public nonisolated struct PagePushKind: Hashable, Sendable {
    /// The kind's name, unique among kinds.
    public let name: String

    /// - Parameter name: The kind's name, unique among kinds.
    public init(_ name: String) {
        self.name = name
    }

    /// The page theme (`WebTheme.applyScript`).
    public static let theme = PagePushKind("theme")
    /// The `--cmux-interface-scale` token (`DesignSettings.interfaceScaleScript`).
    public static let interfaceScale = PagePushKind("interfaceScale")
    /// The `data-*` attributes of `<html>` (PageWebView+LiveAttributes.swift).
    public static let documentAttributes = PagePushKind("documentAttributes")
    /// The URL fragment the host asked for (``PageWebView/open(route:)``).
    public static let route = PagePushKind("route")
    /// The first-paint probe (``PagePaintProbe``).
    public static let paintProbe = PagePushKind("paintProbe")
    /// The glass lenses' wallpaper still (`GlassBackdropFeed`): a held push carries the whole state, as the
    /// feed sends everything after a push the page held (`GlassBackdropFeed.pushWasHeld()`).
    public static let glass = PagePushKind("glass")
    /// Whether the document shows, for its loops (`cmuxTheme.visibility`, PageWebView+HiddenLoops.swift).
    public static let loopVisibility = PagePushKind("loopVisibility")
}
