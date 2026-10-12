import AppKit
import CmuxNextActions

/// Open Link in Default Browser (cx-k9go): the page's and the terminal's
/// link rows hand the link to the app macOS opens web links with. While
/// that app is cmux itself the row is left out (it would open the link
/// here again), and a run refuses with the reason.
@MainActor
enum DefaultBrowserLink {
    /// The app that opens `url`, and whether it is this cmux.
    struct Handler: Equatable {
        let appURL: URL
        let isCmux: Bool
    }

    /// Reads the system's handler for `url` (tests pass their own).
    static var handler: @MainActor (URL) -> Handler? = { url in
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Handler(appURL: app, isCmux: isCmux(app, main: Bundle.main))
    }

    /// Opens the link in the handler app (tests replace it).
    static var open: @MainActor (URL, URL) -> Void = { url, app in
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Whether `app` is this cmux: the running bundle, or a cmux build of the same identifier.
    nonisolated static func isCmux(_ app: URL, main: Bundle) -> Bool {
        if app.standardizedFileURL == main.bundleURL.standardizedFileURL { return true }
        guard let id = Bundle(url: app)?.bundleIdentifier, let mine = main.bundleIdentifier else { return false }
        return id == mine
    }

    static func bind(into registry: ActionRegistry) {
        registry.bind("openLinkInDefaultBrowser", run: { invocation in
            let url = try BrowserHitHandlers.url(invocation)
            guard let handler = handler(url) else { throw ActionFailure(message: MiscHandlerStrings.noDefaultBrowser) }
            guard !handler.isCmux else { throw ActionFailure(message: MiscHandlerStrings.defaultBrowserIsCmux) }
            open(url, handler.appURL)
        })
        ActionTargetVisibility.hide("openLinkInDefaultBrowser", in: registry) { invocation in
            guard let url = try? BrowserHitHandlers.url(invocation) else { return false }
            return handler(url)?.isCmux ?? true
        }
    }
}
