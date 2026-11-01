public import AppKit
public import CmuxNextSettings
import CmuxNextCompat

/// The one place a link the person clicks in cmux goes (cx-ir3z4): terminals, agent chats, the
/// Home transcript, cmux pages, the Help menu and update notes all open through ``shared``. The
/// rule is ``LinkRouting`` (`browser.openLinksInCmuxBrowser`, `.hostsToOpenInEmbeddedBrowser`,
/// `.urlsToAlwaysOpenExternally`): an http(s) link opens in a cmux browser tab unless the rule
/// sends it to the default browser; any other scheme goes to the system. The App sets the
/// closures once at launch; before that a link goes to the system.
public final class LinkRouter {
    public static let shared = LinkRouter()

    /// The routing settings, read on every open.
    public var routing: () -> LinkRouting = { .fallback }
    /// `files.textEditor`, read when a path menu opens.
    public var textEditor: () -> String = { "" }
    /// A link this app opens itself whatever the setting (a Chief subagent's link); true when it did.
    public var appLink: (URL) -> Bool = { _ in false }
    /// Opens a web link in a cmux browser tab of the current window, in the background (not
    /// selected) when asked. `source` is the tab the link was clicked in (a tab id), nil for the
    /// focused pane: the App places the tab beside it (`layout.linkPlacement`).
    public var openInCmux: (_ url: URL, _ background: Bool, _ source: String?) -> Void = { url, _, _ in NSWorkspace.shared.openInBackground(url) }
    /// The tab (a tab id) of the pane showing a clicked view, nil when no pane shows it: the App
    /// finds the pane holding the view (``open(_:otherTarget:from:)``).
    public var sourceTab: (_ view: NSView) -> String? = { _ in nil }

    #if DEBUG
    /// `CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS=1` (live scripts): what would go to another app is
    /// recorded instead of opened. Every open is recorded either way (``recorded``).
    public let recordsExternalOpens = ProcessInfo.processInfo.environment["CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS"] == "1"
    /// Where links went, oldest first: `browser:<url>` (`browser-background:` for a background
    /// tab), `system:<url>`, `app:<app name>:<path>`, `default:<path>` (its default app), `finder:<path>`, `file:<path>` (a cmux file page).
    public var recorded: [String] = []
    #endif

    public init() {}

    /// Shift-Command on a click: open the link in the browser the setting does not pick.
    public static func isOtherTarget(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask).isSuperset(of: [.command, .shift])
    }

    /// Command without Shift on a click: the link's tab opens in the background, as Chrome's
    /// Cmd-click does; a plain click's tab takes the focus (Leo 2026-10-21).
    public static func opensInBackground(_ flags: NSEvent.ModifierFlags) -> Bool {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command) && !flags.contains(.shift)
    }

    /// Where `url` goes now (``LinkRouting/target(for:otherTarget:explicit:)``).
    public func target(for url: URL, otherTarget: Bool = false, explicit: Bool = false) -> LinkRouting.Target {
        routing().target(for: url, otherTarget: otherTarget, explicit: explicit)
    }

    /// Opens a clicked link where the rule sends it; `otherTarget` is Shift-Command on the click,
    /// `background` a page's Cmd-click, `source` the tab it was clicked in (nil: the focused pane).
    /// Returns where it went, nil for an app link.
    @discardableResult
    public func open(_ url: URL, otherTarget: Bool = false, explicit: Bool = false, background: Bool = false,
                     source: String? = nil) -> LinkRouting.Target? {
        if appLink(url) { return nil }
        let target = target(for: url, otherTarget: otherTarget, explicit: explicit)
        open(url, in: target, background: background, source: source)
        return target
    }

    /// Opens a link clicked in `view` (a chat transcript, a cmux page) where the rule sends it,
    /// beside the pane that shows `view` (``sourceTab``), not the focused pane: Cmd-click always
    /// lands right of what was clicked.
    @discardableResult
    public func open(_ url: URL, otherTarget: Bool = false, from view: NSView) -> LinkRouting.Target? {
        open(url, otherTarget: otherTarget, source: sourceTab(view))
    }

    /// Opens a link clicked in `view` with `modifiers` held (``open(_:otherTarget:from:)``):
    /// Shift-Command picks the other browser, Command alone opens the tab in the background.
    @discardableResult
    public func open(_ url: URL, modifiers: NSEvent.ModifierFlags, from view: NSView) -> LinkRouting.Target? {
        open(url, otherTarget: Self.isOtherTarget(modifiers), background: Self.opensInBackground(modifiers), source: sourceTab(view))
    }

    /// Opens `url` in `target` whatever the link setting (a menu's Open in cmux Browser, Open in
    /// Default Browser). A non-web URL never opens in cmux, nor any URL while the cmux browser is
    /// off (`browser.enabled`). `source` is the tab it was clicked in (nil: the focused pane).
    public func open(_ url: URL, in target: LinkRouting.Target, background: Bool = false, source: String? = nil) {
        let web = url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
        if target == .cmuxBrowser, web, routing().browserEnabled {
            record((background ? "browser-background:" : "browser:") + url.absoluteString)
            openInCmux(url, background, source)
            return
        }
        if recordsInstead("system:" + url.absoluteString) { return }
        // Never the blocking open: a click handler may hold a renderer lock.
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens a link a terminal program asked a browser for (`browser.open_link`) in cmux: in a cmux
    /// browser tab whatever the rule when `explicit` (a `target` or a `terminal.linkOpener` rule
    /// names cmux), else where the rule sends it, beside `source`, the tab of the caller's terminal.
    /// Returns where it went (an app link counts as cmux), or nil when it opened nothing because
    /// `terminal` was named but no tab shows it (`source` nil) and the link would open in a cmux
    /// tab: that tab never lands beside whichever pane has focus, which may be another window or
    /// browser profile (#29224). With no `terminal` the focused pane is meant.
    public func openTerminalLink(_ url: URL, terminal: String?, source: String?, explicit: Bool,
                                 background: Bool) -> LinkRouting.Target? {
        if terminal != nil, source == nil, routing().browserEnabled, explicit || target(for: url) == .cmuxBrowser { return nil }
        guard explicit else { return open(url, background: background, source: source) ?? .cmuxBrowser }
        open(url, in: .cmuxBrowser, background: background, source: source)
        return routing().browserEnabled ? .cmuxBrowser : .system
    }

    /// Opens `file` (or a web link) with the app at `app`.
    public func open(_ url: URL, withApplicationAt app: URL) {
        if recordsInstead("app:\(app.deletingPathExtension().lastPathComponent):\(url.isFileURL ? url.path : url.absoluteString)") { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens a file or folder in its default app (a folder in Finder).
    public func openFile(_ file: URL) {
        if recordsInstead("default:" + file.path) { return }
        NSWorkspace.shared.openInBackground(file)
    }

    /// A folder opens in Finder; a package (an app, a bundle) and a file show selected in their
    /// folder, never launched.
    public func showInFinder(_ url: URL, reveal: Bool = false) {
        if recordsInstead("finder:" + url.path) { return }
        if reveal || (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
            NSWorkspace.shared.revealInBackground([url])
        } else {
            NSWorkspace.shared.openInBackground(url)
        }
    }

    public func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Records `entry` (DEBUG); true when the open must not happen (a recording run).
    private func recordsInstead(_ entry: String) -> Bool {
        record(entry)
        #if DEBUG
        return recordsExternalOpens
        #else
        return false
        #endif
    }

    public func record(_ entry: String) {
        #if DEBUG
        recorded.append(entry)
        #endif
    }
}
