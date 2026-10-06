import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon

/// The page menu's link, image and selection actions (R123,
/// `BrowserHitMenu`). Each takes the hit's `url` (and `text`), so the
/// palette, the CLI and MCP run the same handler as the menu row. With a
/// page (the right-clicked tab, else the focused one) a link opens on the
/// page's engine and browser profile through `BrowserPageRequests`; with
/// none (a CLI call from a terminal) the focused pane and the default
/// engine take it.
enum BrowserHitHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext,
                     pasteboard: @escaping @MainActor () -> any BrowserPasteboard = { NSPasteboard.general }) {
        bindOpen(registry, context)
        bindPlaces(registry, context)
        bindCopy(registry, context, pasteboard)
        bindSave(registry, context)
        bindSelection(registry, context)
    }

    // MARK: Arguments

    /// The `url` argument: an address with a scheme, never `javascript:`
    /// (a link row would run it in a blank page).
    static func url(_ invocation: ActionInvocation) throws -> URL {
        guard let text = invocation["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme != "javascript" else {
            throw ActionFailure.invalidTarget(BrowserHitStrings.urlRequired)
        }
        return url
    }

    static func text(_ invocation: ActionInvocation) throws -> String {
        guard let text = invocation["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActionFailure.invalidTarget(BrowserHitStrings.textRequired)
        }
        return text
    }

    /// The page the run acts for: the target tab's, else the focused one.
    static func page(_ invocation: ActionInvocation, _ context: AppActionContext) -> (any BrowserTab)? {
        try? context.page(invocation).tab
    }

    // MARK: Open

    private static func bindOpen(_ registry: ActionRegistry, _ context: AppActionContext) {
        registry.bind("browser.link.openInNewTab", run: { try Self.open(Self.url($0), .backgroundTab, $0, context) })
        registry.bind("browser.image.openInNewTab", run: { try Self.open(Self.url($0), .backgroundTab, $0, context) })
        registry.bind("browser.link.openInNewWindow", run: { try Self.open(Self.url($0), .newWindow, $0, context) })
        registry.bind("browser.link.openInIncognitoWindow", run: { invocation in
            context.services.openOffTheRecord(try Self.url(invocation), source: Self.page(invocation, context))
        })
        registry.bind("browser.link.openInSplit", requires: DaemonCapabilities.shared.frontendBrowserTabs, daemon: context.daemon, run: { invocation in
            let url = try Self.url(invocation)
            let pane = try context.pane(invocation)
            let services = context.services
            let profile = Self.page(invocation, context).flatMap { services.cache.key(of: $0) }.flatMap { services.cache.tabModel($0) }
                .map { services.browserProfiles.profileID(ofTab: $0) }
            try BrowserHandlers.splitBrowser(from: pane, direction: .right, url: url, profile: profile, context: context)
        })
    }

    /// A new tab next to the page (its engine, profile and pane), a new
    /// window holding a new workspace, or, without a page, a tab in the
    /// focused pane.
    static func open(_ url: URL, _ disposition: BrowserNewTabDisposition, _ invocation: ActionInvocation,
                     _ context: AppActionContext) throws {
        if let page = Self.page(invocation, context) {
            return context.services.cache.pageRequests.browserTab(page, didRequest: .openURL(url, disposition))
        }
        if disposition == .newWindow { return try Self.openWorkspace(url, newWindow: true, window: nil, room: nil, context.services) }
        context.paneController(invocation)?.newBrowserTab(url: url, background: disposition == .backgroundTab)
    }

    // MARK: Workspaces and spaces

    private static func bindPlaces(_ registry: ActionRegistry, _ context: AppActionContext) {
        registry.bind("browser.link.openInNewWorkspace", run: { invocation in
            let url = try Self.url(invocation)
            let window = context.scope(invocation).pane.flatMap { context.services.windowController(showing: $0) }?.state.id
            guard let page = Self.page(invocation, context) else {
                return try Self.openWorkspace(url, newWindow: false, window: window, room: nil, context.services)
            }
            context.services.cache.pageRequests.openInNewWorkspace(url, opener: page, newWindow: false, window: window)
        })
        registry.bind("browser.link.openInNewSpace", requires: DaemonCapabilities.shared.profiles,
                      daemon: context.services.machines.local, run: { invocation in
            try context.requireRooms()
            let url = try Self.url(invocation)
            let services = context.services
            let page = Self.page(invocation, context)
            // The window enters the new space and shows a new workspace that
            // holds the page, instead of the terminal workspace a switch to an
            // empty space opens.
            try RoomHandlers.create(invocation: ActionInvocation(), context, action: "browser.link.openInNewSpace") { [weak page] room, state in
                state.enterProfile(room)
                services.windows.recordSaver.stateDidChange(state)
                if let page {
                    services.cache.pageRequests.openInNewWorkspace(url, opener: page, newWindow: false, window: state.id, room: room)
                } else {
                    try? Self.openWorkspace(url, newWindow: false, window: state.id, room: room, services)
                }
            }
        })
    }

    /// A new workspace whose only tab shows `url` on the default engine.
    static func openWorkspace(_ url: URL, newWindow: Bool, window: String?, room: ProfileID?, _ services: AppServices) throws {
        let daemon = services.activeDaemon
        guard daemon.supports(DaemonCapabilities.shared.frontendBrowserTabs) else {
            throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapabilities.shared.frontendBrowserTabs))
        }
        guard let browserTabs = services.cache.browserTabs, case .open(let choice) = browserTabs.resolve(requested: nil) else { return }
        let address = url.absoluteString
        WorkspaceHandlers.createAndShow(services: services, newWindow: newWindow, window: window, room: room) { connection, terminal in
            guard let pane = terminal.pane else { return }
            _ = try await connection.newFrontendBrowserTab(url: address, engine: choice.engine, in: pane)
            if let surface = terminal.surface { try await connection.closeTab(surface) }
        }
    }

    // MARK: Selection

    private static func bindSelection(_ registry: ActionRegistry, _ context: AppActionContext) {
        // A new selected tab, as in Chrome, with the omnibar's search engine.
        registry.bind("browser.selection.search", run: { invocation in
            let text = try Self.text(invocation)
            guard let url = context.services.cache.suggestionEngine.resolver.searchEngine.searchURL(for: text) else {
                throw ActionFailure.invalidTarget(BrowserHitStrings.textRequired)
            }
            try Self.open(url, .foregroundTab, invocation, context)
        })
        // The system dictionary panel, over the page.
        registry.bind("browser.selection.lookUp", run: { invocation in
            let text = try Self.text(invocation)
            guard let view = Self.page(invocation, context)?.contentView, view.window != nil else {
                throw ActionFailure(message: BrowserHitStrings.noPage)
            }
            view.showDefinition(for: NSAttributedString(string: text), at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        })
    }
}
