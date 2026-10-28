import AppKit
import CmuxNextActions
import CmuxNextCompatAppKit
import CmuxNextWakeups

/// Open Link in Default Browser (cx-k9go): the page's and the terminal's
/// link rows hand the link to the app macOS opens web links with. While
/// that app is cmux itself the row is left out (it would open the link
/// here again), and a run refuses with the reason. The handler comes from Launch Services on the system lane
/// (``WorkspaceQueries``), kept per scheme: the row's visibility reads the kept answer, and the run awaits it.
@MainActor
enum DefaultBrowserLink {
    /// The app that opens `url`, and whether it is this cmux.
    nonisolated struct Handler: Equatable, Sendable {
        let appURL: URL
        let isCmux: Bool
    }

    /// The system's handler for links of `scheme`, asked on the system lane (the app's bundle is read there too).
    nonisolated static func query(scheme: String) -> WorkspaceQuery<Handler?> {
        WorkspaceQuery(id: "links.defaultBrowser." + scheme, refreshes: true) { system in
            guard let probe = URL(string: scheme + "://example.com/"), let app = system.defaultApplication(toOpen: probe) else { return nil }
            return Handler(appURL: app, isCmux: Self.isCmux(app, main: Bundle.main))
        }
    }

    /// The system's handler for `url`: the kept answer, else asked on the system lane.
    static func handler(_ url: URL, queries: WorkspaceQueries) async throws -> Handler? {
        try await queries.value(Self.query(scheme: url.scheme?.lowercased() ?? "https"), priority: .userBlocking)
    }

    /// Opens the link in the handler app (tests replace it).
    static var open: @MainActor (URL, URL) -> Void = { url, app in
        NSWorkspace.shared.openInBackground([url], withApplicationAt: app)
    }

    /// Whether `app` is this cmux: the running bundle, or a cmux build of the same identifier.
    nonisolated static func isCmux(_ app: URL, main: Bundle) -> Bool {
        if app.standardizedFileURL == main.bundleURL.standardizedFileURL { return true }
        guard let id = Bundle(url: app)?.bundleIdentifier, let mine = main.bundleIdentifier else { return false }
        return id == mine
    }

    static func bind(into registry: ActionRegistry, queries: WorkspaceQueries) {
        registry.bindEffect("openLinkInDefaultBrowser", effect: { invocation in
            let url: URL
            do { url = try BrowserHitHandlers.url(invocation) } catch { return .refused((error as? ActionFailure)?.message ?? error.localizedDescription) }
            // action-wait-allow: the default browser is known only when Launch Services answers on the system lane; then it opens.
            return .waiting(.externalProcess) {
                guard let handler = (try? await Self.handler(url, queries: queries)) ?? nil else {
                    return ActionWorkFailure(MiscHandlerStrings.noDefaultBrowser)
                }
                guard !handler.isCmux else { return ActionWorkFailure(MiscHandlerStrings.defaultBrowserIsCmux) }
                Self.open(url, handler.appURL)
                return nil
            }
        })
        // Warmed now, so the first link menu knows the default browser (Chrome's DefaultBrowserWorker asks at start).
        queries.prefetch(["http", "https"].map { Self.query(scheme: $0) }, priority: .bestEffort)
        // The row shows only once the kept answer says the default browser is another app; a miss asks for it.
        ActionTargetVisibility.hide("openLinkInDefaultBrowser", in: registry) { invocation in
            guard let url = try? BrowserHitHandlers.url(invocation) else { return false }
            let question = Self.query(scheme: url.scheme?.lowercased() ?? "https")
            guard let kept = queries.cached(question) else {
                queries.prefetch([question], priority: .userBlocking)
                return true
            }
            return kept?.isCmux ?? true
        }
    }
}
