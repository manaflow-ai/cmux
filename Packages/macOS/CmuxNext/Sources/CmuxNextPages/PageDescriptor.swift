public import Foundation
import CmuxNextSettings

/// One React page the app hosts (plans/cmux-next/react-pages.md 1, pane-protocol.md "Pages"):
/// its id (also the origin host, `cmux-page://<id>`), its bundled resource directory, and what it
/// may call. One origin per page id, so a page never shares an origin with another page.
public nonisolated struct PageDescriptor: Sendable, Hashable {
    public static let scheme = "cmux-page"

    /// `cmux.history`, `cmux.apps`, `cmux.settings`.
    public let id: String
    /// The directory under `Resources/pages/` that holds the page's `index.html`.
    public let resource: String
    /// Op and stream name prefixes the page may use (`cmux.history.`).
    public let namespaces: [String]
    /// Native UI ops the page may call (`cmux.app.action.run`).
    public let nativeOps: Set<String>
    /// Ops never allowed from this page even inside its namespaces (`cmux.settings.domains.publish`).
    public let denied: Set<String>
    /// Registry actions the page may run through `cmux.app.action.run` (`history.open`). A page
    /// runs nothing else, so a page bug cannot reach unrelated app actions.
    public let actions: Set<String>
    /// Of ``actions``, those the person's own fresh click or key in the page view runs as theirs
    /// (origin `user`, as the palette and menus run it), one gesture spent per run
    /// (``PageGestureActionProvider``): an action whose handler only opens its setup sheet for the person
    /// (`newCloudMachine` on Home). Page script alone, or a spent gesture, still runs it as `page`.
    public let gestureActions: Set<String>
    /// The dispatcher commands this page takes on `cmux.page.command` (default: every page command).
    public let commands: Set<String>
    /// Namespace ops the page may only run through `cmux.app.action.run {action: <op>, args}`: the
    /// host shows the native confirmation of that kind, then runs the op as the user's own
    /// (deleting data, money, publishing, signing in). The page never calls them directly.
    public let confirmedOps: [String: PageConfirmation.Kind]
    /// The page's Content Security Policy (``PageCSP``); strict unless a first-party page widens it, or
    /// another built-in page adds image sources.
    public let csp: PageCSP
    /// The file `cmux-page://<id>/` serves (default `index.html`): a page whose root is a shared
    /// build (the diff viewer in the one webviews-app build) names its own entry html.
    public let entry: String
    /// First path components the page instance's ``PageDynamicResourceSource`` answers
    /// (`__patch`); the scheme handler never serves a static file under one.
    public let dynamicPrefixes: Set<String>
    /// The page has its own search field: Cmd-F (the `find` action) sends it
    /// `focusSearch`, which focuses and selects that field (Settings,
    /// Keyboard Shortcuts, Passwords), instead of a find bar.
    public let ownsSearchField: Bool
    /// A first click in an inactive window reaches the page (``PageWKWebView``), as on the native
    /// controls. Off by default (fail closed): a page opts in only when no control on it acts on one
    /// click without a host confirmation sheet, so a click that only meant to bring the window
    /// forward cannot run one (Settings' browsing-data Clear, the agent pane's permission cards,
    /// Push, Apply and Remove, an app page's own content; those also say false explicitly, so a
    /// later default change cannot turn them on). A page that is off keeps WebKit's answer.
    public let acceptsFirstMouse: Bool
    /// The page shows saved documents in passive (sandboxed, scriptless) srcdoc frames, as the agent
    /// pane does: a frame's `about:srcdoc` load from the page's own document is allowed, and any
    /// navigation such a frame starts, or that would replace its document, is cancelled
    /// (``PageNavigation``). Off by default: other pages' frames keep their navigation hook.
    public let passiveFrames: Bool
    /// The page belongs to the Chief chat (Bring your history): Agent Chat Zoom scales it too
    /// (``PageWebView/followsChatZoom``). Off by default: a page keeps `app.uiScale` alone.
    public let followsChatZoom: Bool

    public init(id: String, resource: String, namespaces: [String], nativeOps: Set<String> = [], denied: Set<String> = [],
                actions: Set<String> = [], gestureActions: Set<String> = [], commands: Set<String> = PageNativeOp.commands,
                confirmedOps: [String: PageConfirmation.Kind] = [:], csp: PageCSP = .strict, entry: String = "index.html",
                dynamicPrefixes: Set<String> = [], ownsSearchField: Bool = false, acceptsFirstMouse: Bool = false,
                passiveFrames: Bool = false, followsChatZoom: Bool = false) {
        self.id = id
        self.resource = resource
        self.namespaces = namespaces
        self.nativeOps = nativeOps
        self.denied = denied.union(confirmedOps.keys)
        self.actions = actions
        self.gestureActions = gestureActions.intersection(actions)
        self.commands = commands
        self.confirmedOps = confirmedOps
        // Only a first-party page may widen its policy (PageID). Another built-in (`cmux.`) page may
        // add image sources only (the GitHub page's image proxy), which loads pixels and runs nothing,
        // and keeps no daemon access, while its own narrowing (inline script off) stands (review
        // follow-up on #38075, F2); any other id gets the strict one.
        self.csp = PageID.isFirstParty(id) ? csp
            : PageID.isReserved(id) ? PageCSP(image: csp.image, inlineScript: csp.inlineScript) : .strict
        // One file name inside the root, never a path.
        self.entry = entry.isEmpty || entry.contains("/") || entry.hasPrefix(".") ? "index.html" : entry
        self.dynamicPrefixes = dynamicPrefixes
        self.ownsSearchField = ownsSearchField
        self.acceptsFirstMouse = acceptsFirstMouse
        self.passiveFrames = passiveFrames
        self.followsChatZoom = followsChatZoom
    }

    /// Whether the page may call `op` (or subscribe to the stream `op`).
    public func admits(_ op: String) -> Bool {
        guard !denied.contains(op) else { return false }
        return nativeOps.contains(op) || namespaces.contains { op.hasPrefix($0) && op.count > $0.count }
    }

    /// `cmux-page://<id>`.
    public var origin: String { "\(Self.scheme)://\(id)" }

    /// The page URL, with `route` as the fragment (`#/settings/appearance?focus=<key>`). A route's
    /// valid escapes stay as they are (a fragment the page read from `location.hash`, where `%26`
    /// is a `&` inside a value, not a separator); everything else the fragment may not hold is encoded.
    public func url(route: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = id
        components.path = "/"
        if let route, !route.isEmpty {
            let fragment = route.hasPrefix("#") ? String(route.dropFirst()) : route
            if fragment.removingPercentEncoding != nil, let encoded = fragment.addingPercentEncoding(withAllowedCharacters: Self.encodedFragmentCharacters) {
                components.percentEncodedFragment = encoded
            } else {
                components.fragment = fragment
            }
        }
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// What an already encoded fragment may hold as is: the fragment's characters and the escapes' `%`.
    private static let encodedFragmentCharacters = CharacterSet.urlFragmentAllowed.union(CharacterSet(charactersIn: "%"))

    /// Whether `url` is a document of this page (its own origin).
    public func owns(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == Self.scheme && url.host?.lowercased() == id.lowercased()
    }
}

/// The native UI ops every page shares (react-pages.md 1.3). The host serves them; a page lists
/// the ones it uses in ``PageDescriptor/nativeOps``.
public nonisolated struct PageNativeOp {
    public nonisolated init() {}
    /// Runs a registry action in the app with origin `user`: `{action, args}`.
    public static let actionRun = "cmux.app.action.run"
    /// The refusal of a person-only action (``ActionDescriptor/isPersonOnly``) that a page asked
    /// for without a real click or key in the page view.
    public static let userOnlyCode = "cmux.app.user_only"
    /// Writes text to the pasteboard: `{text}`. Only within a moment of a real key, click or native
    /// context menu choice in the page view (`PageCallContext.userGesture`); otherwise refused with
    /// ``userOnlyCode``.
    public static let clipboardWrite = "cmux.app.clipboard.write"
    /// Runs `{command}` (`cut`, `copy`, `paste`, `pasteAsPlainText`) as the page view's own
    /// responder action, for a page's own text-field menu: the page never reads the pasteboard.
    /// Only on the person's click or key in the page view, each spent once. Served by the page's own
    /// route (the Channels page's `PageEditProvider`), not the shared `cmux.app.` provider.
    public static let edit = "cmux.app.edit"
    /// Stream every page may subscribe to: `{command, text?}` from the app's key dispatcher
    /// (`find`, `focusSearch`, `back`, `forward`, `reset`). The page never reads chords itself.
    public static let pageCommand = "cmux.page.command"
    /// Built in for every page (DESKTOP-FEEL, R139): a double-click on a title bar the page draws
    /// (`data-titlebar`) runs the window's title bar action (System Settings: zoom or minimize).
    public static let titleBarDoubleClick = "cmux.app.window.title_bar_double_click"
    /// Stream every page may subscribe to: `{connected}`, the page's owner link (the daemon). The
    /// current state arrives as the first event.
    public static let pageConnection = "cmux.page.connection"
    /// Built in for every page (cx-6k6cg): a small transient surface with no room in the page shows
    /// its rows past the window's edge (WebPopupHost): `show`, `update` and `hide`.
    public static let popupShow = "cmux.app.popup.show"
    public static let popupUpdate = "cmux.app.popup.update"
    public static let popupHide = "cmux.app.popup.hide"
    /// Stream every page may subscribe to: the popup's `pick`, `highlight` and `dismiss`.
    public static let pagePopup = "cmux.page.popup"
    /// Built in for every page: a right-click menu (`ui/ContextMenu.tsx`) shown as a standard macOS
    /// menu (``WebContextMenu``); answers `{picked: id}` once it closes, `picked` null when dismissed.
    public static let contextMenu = "cmux.app.contextMenu.show"
    /// The page command the host sends each time the page's web view becomes first responder: the
    /// page focuses its primary input when nothing in it has focus (pane-focus-DESIGN.md P1).
    public static let focusContent = "focusContent"
    /// The page commands the dispatcher sends (the Settings lead's page pattern), and
    /// ``focusContent``.
    public static let commands: Set<String> = ["find", "focusSearch", "back", "forward", "reset", focusContent]
}

public extension PageDescriptor {
    /// The Cloud app page (`cmux/cloud`, plans/cmux-next/cloud-app.md L7; React page by the Cloud
    /// lead). Deleting, publishing, firewall changes, billing, sign-in/out and connect run only
    /// through the native confirmation.
    static let cloud = PageDescriptor(
        id: "cmux.cloud", resource: "cloud", namespaces: ["cmux.cloud."],
        nativeOps: [PageNativeOp.actionRun, PageNativeOp.clipboardWrite],
        actions: ["cloudPreviewShare", "cloudPreviewRevoke"],
        confirmedOps: [
            "cmux.cloud.machine.delete": .delete, "cmux.cloud.snapshot.delete": .delete,
            // Automatic cleanup: archive and delete removes the machine (its disk kept as an archive);
            // restore makes a machine from an archive (a money op, titled with the machine's name).
            "cmux.cloud.machine.archive_delete": .delete, "cmux.cloud.snapshot.restore": .custom,
            "cmux.cloud.publication.delete": .delete, "cmux.cloud.firewall.delete": .delete,
            "cmux.cloud.publication.create": .custom, "cmux.cloud.firewall.create": .custom,
            "cmux.cloud.billing.open": .custom, "cmux.cloud.auth.sign_in": .custom,
            "cmux.cloud.auth.sign_out": .custom, "cmux.cloud.machine.connect": .custom,
        ])

    /// The Settings page (R82: the only Settings UI). Its `cmux.settings.` ops and the native
    /// preview and sound ops share the namespace; the page may run only its own actions and the
    /// sections' buttons, and writes the pasteboard for a row's Copy Setting Key.
    // Agents > Chiefs draws the Chief editor: the Chief owner through the host's page relay
    // (`cmux.chief.profile.`) and the harness center (`cmux.chief.backend.`), as Home does.
    // These notes sit above the call: gallery-coverage reads the id right after the open parenthesis.
    static let settings = PageDescriptor(
        id: "cmux.settings", resource: "settings", namespaces: ["cmux.settings.", "cmux.chief.profile.", "cmux.chief.backend."],
        nativeOps: [PageNativeOp.actionRun, PageNativeOp.clipboardWrite],
        actions: Set<String>(["palette.openCmuxSettingsFile", "openSettings", "browserProfile.new", "browserProfile.rename",
                  "browserProfile.setColor", "browserProfile.clearColor", "browserProfile.setIcon", "browserProfile.clearIcon",
                  "browserProfile.manageExtensions", "browserProfile.delete", "browserProfile.clearBrowsingData",
                  "reloadConfiguration",
                  // Machines > Add Server… opens the Add Server card (no code: the page never approves).
                  "server.addServer",
                  // Machines > Add Device… opens the one Add Device card (add-device-DESIGN.md).
                  "device.add",
                  // Agents > Computer Use card (ComputerUseSetup).
                  "palette.computerUse.setup", "palette.computerUse.accessibility", "palette.computerUse.screenRecording", "palette.computerUse.restart",
                  // Settings › Import's cards (CmuxNextImportCards): a card's button, and Import from Browser.
                  "import.card", "importFromBrowser"])
            .union(settingsSectionActions),
        dynamicPrefixes: ["backdrop", "museum", "icon", "symbol"], ownsSearchField: true, acceptsFirstMouse: false)

    /// The App Store page (react-pages.md 3). Install, update, Remove, `set` and allowing a scope pass
    /// the host's native sheet before they reach the owner (the app's ConfirmingPageProvider); Open
    /// runs the registry action `app.open` (a host verb, cx-hnmbt.13).
    /// Its icons are the host's drawings (``AppsPageNativeOps/glyphPrefix``).
    static let apps = PageDescriptor(
        id: "cmux.apps", resource: "apps", namespaces: ["cmux.apps."], nativeOps: [PageNativeOp.actionRun],
        actions: ["app.open"], dynamicPrefixes: [AppsPageNativeOps.glyphPrefix])

    /// The CodeRouter page (coordinator decision: a separate page for the CodeRouter dashboard;
    /// Settings > Accounts links to it). Its ops are the CodeRouter app's `coderouter.*` family;
    /// the page runs only three account actions. Connect adds a credential, so it is the host op
    /// `cmux.coderouter.accounts.connect` behind the app's native sheet, never a plain action.
    static let coderouter = PageDescriptor(
        id: "cmux.coderouter", resource: "coderouter", namespaces: ["cmux.coderouter."], nativeOps: [PageNativeOp.actionRun],
        actions: ["palette.auth.signIn", "accounts.reauthenticate", "accounts.refresh"])

    /// The buttons at the end of each Settings section (`SettingsSchema.actions(in:)`), which the
    /// page runs through cmux.app.action.run with origin page (the actions' own rules still apply).
    static let settingsSectionActions: Set<String> = Set(SettingsSection.allCases.flatMap { section in
        SettingsSchema.actions(in: section).map(\.rawValue)
    })

    /// The changelog page (R114): signed release notes, read only. Its only native op runs a
    /// highlight's "Try it", and only for an action in ``changelogTryItActions``: the signed
    /// notes may name an action id, never a command or a URL. Its one network source is the
    /// nightly reels' folder (``changelogReelSource``), so the update's reel plays in the page.
    /// A highlight's PR chip opens its link through the owner's `cmux.changelog.browser.openIn`,
    /// which takes only https and spends the person's gesture (ChangelogPageProvider).
    static let changelog = PageDescriptor(
        id: "cmux.changelog", resource: "changelog", namespaces: ["cmux.changelog."],
        nativeOps: [PageNativeOp.actionRun], actions: changelogTryItActions,
        csp: PageCSP(media: ["data:", changelogReelSource]))

    /// The GitHub page (webviews/src/pages/github, its owner CmuxNextGitHubViewer's GitHubPageProvider): a pull
    /// request drawn from the app's pull request cache, with no github.com page load. One tab per workspace, which
    /// every pull request link of a chat moves to its own route (`#/pull?url=`), so a second link is a route change
    /// in a page already running, never a new tab or a new web page.
    /// Its only remote images are the ones GitHub's own rendering of a body points at (`bodyHTML`), which
    /// go through GitHub's image proxy: camo for an outside image, so its host never sees the reader,
    /// and the signed links of images people attached. No other host loads.
    static let github = PageDescriptor(
        id: "cmux.github", resource: "github", namespaces: ["cmux.github."], csp: PageCSP(image: githubImageSources))

    static let githubImageSources = [
        "https://camo.githubusercontent.com", "https://private-user-images.githubusercontent.com",
        "https://user-images.githubusercontent.com", "https://avatars.githubusercontent.com",
    ]

    /// The browser's Page Info bubble (webviews/src/pages/page-info, its owner CmuxNextBrowser's
    /// PageInfoController through the App's BrowserChromeWebHost): one page per pane, kept between
    /// opens. `cmux.page-info.state` brings the bubble's state; the page sends its commands and size.
    static let pageInfo = PageDescriptor(id: "cmux.page-info", resource: "page-info", namespaces: ["cmux.page-info."])

    /// Page Info's windows (webviews/src/pages/site-settings, site-data, certificate), each in a
    /// native window CmuxNextBrowser's PageInfoWindows owns: `cmux.<page>.state` brings the
    /// window's state; the page sends its commands and its content height.
    static let siteSettings = PageDescriptor(id: "cmux.site-settings", resource: "site-settings", namespaces: ["cmux.site-settings."])
    static let siteData = PageDescriptor(id: "cmux.site-data", resource: "site-data", namespaces: ["cmux.site-data."])
    static let certificate = PageDescriptor(id: "cmux.certificate", resource: "certificate", namespaces: ["cmux.certificate."])
    /// The browser's Import Cookies card (webviews/src/pages/cookie-import, its owner CmuxNextBrowser's
    /// BrowserCookieImportCard through BrowserChromeWebHost), inside the card's native glass on the
    /// window's overlay. `cmux.cookie-import.state` brings the card's lines; the page sends the
    /// person's answer and its size. It takes the first click: the card's window is never key.
    static let cookieImport = PageDescriptor(id: "cmux.cookie-import", resource: "cookie-import", namespaces: ["cmux.cookie-import."],
                                             acceptsFirstMouse: true)

    /// Where the nightly publishes each build's reel (`ReleaseMediaStore.reelBase`): the changelog
    /// page's `media-src`, a folder, so nothing else on that host plays.
    static let changelogReelSource = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/nightly-next/"

    /// The actions a changelog "Try it" may run (compiled in, reviewed with each addition).
    static let changelogTryItActions: Set<String> = [
        "palette.checkForUpdates", "openSettings", "palette.searchShortcuts", "palette.newAgentChat",
        "home.show", "appStore.show", "newBrowserWorkspace", "space.new", "renameWorkspace", "liveWeb.start",
    ]

    /// The Files tree beside a chat (cx-p4rt): one folder, read only. `cmux.files.` lists it and
    /// opens a file; the only native op copies a path.
    static let files = PageDescriptor(
        id: "cmux.files", resource: "files", namespaces: ["cmux.files."], nativeOps: [PageNativeOp.clipboardWrite])

    /// The Tasks page (webviews/src/pages/tasks, plans/cmux-next/tasks.md section 14). Its `cmux.tasks.` ops go
    /// to the daemon, which relays them to the local Tasks owner (cmux-tui/spec/page-router.md, routed namespace
    /// `tasks`); its only native op writes the pasteboard (Copy Command when no owner runs).
    static let tasks = PageDescriptor(
        id: "cmux.tasks", resource: "tasks", namespaces: ["cmux.tasks."], nativeOps: [PageNativeOp.clipboardWrite])

    /// The History page (react-pages.md 2). Its `cmux.history.cookie_backups.` ops are the app's
    /// (the Keychain-encrypted cookie backups); the rest are the daemon's history module.
    static let history = PageDescriptor(
        id: "cmux.history", resource: "history", namespaces: ["cmux.history."],
        nativeOps: [PageNativeOp.actionRun, PageNativeOp.clipboardWrite], actions: ["history.open"])

    /// The Feed page (plans/cmux-next/feed-page.md): the app shows only Chief Home's pinned
    /// Needs you (`#/needs-you`); the Inbox tab (`#/inbox`) and the right sidebar's Feed
    /// (`#/list`) have no entry point now. Its `cmux.feed.` ops go to the daemon's feed
    /// client; it opens an item and runs a GitHub action through the host's actions, and Add
    /// Connection opens Settings > Notifications at `feed.github.enabled` (`openSettings`).
    static let feed = PageDescriptor(
        id: "cmux.feed", resource: "feed", namespaces: ["cmux.feed."],
        nativeOps: [PageNativeOp.actionRun, PageNativeOp.clipboardWrite],
        actions: ["feed.openItem", "feed.githubAction", "openSettings"])
    /// The Stashed Tabs page (`cmux://stashed`, a top page): the daemon's stashes (`stash-v1`). The
    /// command `open` with text `import` opens its OneTab paste box (Import from OneTab…).
    static let stash = PageDescriptor(
        id: "cmux.stash", resource: "stash", namespaces: ["cmux.stash."],
        commands: PageNativeOp.commands.union(["open"]), ownsSearchField: true)
}
