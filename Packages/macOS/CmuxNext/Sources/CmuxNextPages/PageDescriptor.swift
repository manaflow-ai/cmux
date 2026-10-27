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
    /// The dispatcher commands this page takes on `cmux.page.command` (default: every page command).
    public let commands: Set<String>
    /// Namespace ops the page may only run through `cmux.app.action.run {action: <op>, args}`: the
    /// host shows the native confirmation of that kind, then runs the op as the user's own
    /// (deleting data, money, publishing, signing in). The page never calls them directly.
    public let confirmedOps: [String: PageConfirmation.Kind]
    /// The page's Content Security Policy (``PageCSP``); strict unless a first-party page widens it.
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

    public init(id: String, resource: String, namespaces: [String], nativeOps: Set<String> = [], denied: Set<String> = [],
                actions: Set<String> = [], commands: Set<String> = PageNativeOp.commands,
                confirmedOps: [String: PageConfirmation.Kind] = [:], csp: PageCSP = .strict, entry: String = "index.html",
                dynamicPrefixes: Set<String> = [], ownsSearchField: Bool = false, acceptsFirstMouse: Bool = false) {
        self.id = id
        self.resource = resource
        self.namespaces = namespaces
        self.nativeOps = nativeOps
        self.denied = denied.union(confirmedOps.keys)
        self.actions = actions
        self.commands = commands
        self.confirmedOps = confirmedOps
        // Only a first-party page may widen its policy (PageID); any other id gets the strict one.
        self.csp = PageID.isFirstParty(id) ? csp : .strict
        // One file name inside the root, never a path.
        self.entry = entry.isEmpty || entry.contains("/") || entry.hasPrefix(".") ? "index.html" : entry
        self.dynamicPrefixes = dynamicPrefixes
        self.ownsSearchField = ownsSearchField
        self.acceptsFirstMouse = acceptsFirstMouse
    }

    /// Whether the page may call `op` (or subscribe to the stream `op`).
    public func admits(_ op: String) -> Bool {
        guard !denied.contains(op) else { return false }
        return nativeOps.contains(op) || namespaces.contains { op.hasPrefix($0) && op.count > $0.count }
    }

    /// `cmux-page://<id>`.
    public var origin: String { "\(Self.scheme)://\(id)" }

    /// The page URL, with `route` as the fragment (`#/settings/appearance?focus=<key>`).
    public func url(route: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = id
        components.path = "/"
        if let route, !route.isEmpty { components.fragment = route.hasPrefix("#") ? String(route.dropFirst()) : route }
        return components.url ?? URL(fileURLWithPath: "/")
    }

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
        confirmedOps: [
            "cmux.cloud.machine.delete": .delete, "cmux.cloud.snapshot.delete": .delete,
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
                  "palette.computerUse.setup", "palette.computerUse.accessibility", "palette.computerUse.screenRecording",
                  // Settings › Import's cards (CmuxNextImportCards): a card's button, and Import from Browser.
                  "import.card", "importFromBrowser"])
            .union(settingsSectionActions),
        dynamicPrefixes: ["backdrop", "museum", "icon"], ownsSearchField: true, acceptsFirstMouse: false)

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
        csp: PageCSP(media: [changelogReelSource]))

    /// Where the nightly publishes each build's reel (`ReleaseMediaStore.reelBase`): the changelog
    /// page's `media-src`, a folder, so nothing else on that host plays.
    static let changelogReelSource = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/nightly-next/"

    /// The actions a changelog "Try it" may run (compiled in, reviewed with each addition).
    static let changelogTryItActions: Set<String> = [
        "palette.checkForUpdates", "openSettings", "palette.searchShortcuts", "palette.newAgentChat",
        "home.show", "appStore.show", "newBrowserWorkspace", "space.new", "renameWorkspace",
    ]

    /// The Files tree beside a chat (cx-p4rt): one folder, read only. `cmux.files.` lists it and
    /// opens a file; the only native op copies a path.
    static let files = PageDescriptor(
        id: "cmux.files", resource: "files", namespaces: ["cmux.files."], nativeOps: [PageNativeOp.clipboardWrite])

    /// The History page (react-pages.md 2).
    static let history = PageDescriptor(
        id: "cmux.history", resource: "history", namespaces: ["cmux.history."],
        nativeOps: [PageNativeOp.actionRun, PageNativeOp.clipboardWrite], actions: ["history.open"])
}
