import AppKit
import CmuxNextActions
import CmuxNextHibernation
import CmuxNextIcons
import CmuxNextPages
import CmuxNextSettings
import Foundation

extension PageDescriptor {
    /// The Passwords page (plans/cmux-next/passwords.md 1.4): cmux-page://cmux.passwords/. It
    /// calls its own namespace, and its Import buttons run the person-only import actions
    /// (PASSWORDS-IMPORT-ANY-BROWSER, cx-d0d.65), which the host runs only on a click or key in the page.
    static let passwords = PageDescriptor(id: "cmux.passwords", resource: "passwords", processGroup: .secrets, namespaces: ["cmux.passwords."],
                                          nativeOps: [PageNativeOp.actionRun], actions: ["importFromBrowser", "browser.importFromFiles"],
                                          ownsSearchField: true)
}

extension InternalPageID {
    static let passwords = InternalPageID(rawValue: "passwords")
}

/// Owns the Passwords page: a React page tab (one per window) whose `cmux.passwords.*` ops the
/// app serves from one ``PasswordStore``. User-only: it opens from the palette (`passwords.open`,
/// person-only), and nothing on the control socket, the CLI or MCP reaches its ops.
@MainActor
final class PasswordsPageService: InternalPageProvider {
    private weak var services: AppServices?
    /// The store every Passwords tab and the browser profile delete sheet read.
    let store: any PasswordStore
    /// Each tab's page, by key, so a discard or a close ends its renderer.
    private var pages: [String: PageWebView] = [:]

    init(services: AppServices, store: (any PasswordStore)? = nil) {
        self.services = services
        self.store = store ?? Self.makeStore(services)
    }

    /// The DEBUG sample store when `CMUX_NEXT_PASSWORDS_SAMPLE=1` (tagged DEV dogfood), else
    /// Chromium's store. Release builds have no sample store at all.
    static func makeStore(_ services: AppServices) -> any PasswordStore {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_NEXT_PASSWORDS_SAMPLE"] == "1" { return SamplePasswordStore() }
        #endif
        return ChromiumPasswordStore(engine: { [weak services] in services?.cache.cef })
    }

    func open(focus: Bool) throws {
        guard let services else { throw ActionFailure(message: RefusalStrings.noWindowOpen) }
        try ChromiumPageRouter.showPasswords(services, focus: focus)
    }

    var page: InternalPageID { .passwords }
    var title: String { PasswordStrings.pageTitle }
    var symbol: String { "key" }
    var icon: IconName? { .securityLock }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        // No app (a released service): no page, as the open below would answer.
        guard let deadlines = services?.mainDeadlines else { return NSView() }
        let provider = PasswordsPageProvider(
            store: store, profiles: { [weak services] in Self.profiles(services) },
            confirmations: DialogPageConfirmationPresenter(), authenticator: LocalDeviceOwnerAuthenticator(),
            secrets: NativePasswordSecretSurface(pasteboard: ConcealedPasteboard(deadlines: deadlines)), mainWork: deadlines.work)
        // `cmux.app.action.run` serves the Import buttons (the page's two person-only actions).
        let native = services.map { AppPageNativeProvider(services: $0, page: .passwords) }
        var routes = [PageRoute(prefix: "cmux.passwords.", provider: provider)]
        if let native { routes.append(PageRoute(prefix: "cmux.app.", provider: native)) }
        guard let page = services?.webUI.open(PageOpenRequest(descriptor: .passwords, routes: routes)) else { return NSView() }
        provider.anchor = { [weak page] in page }
        provider.allowExport = { [weak services] in
            services?.settings.map { BrowserPasswordsSetting.current($0).allowExport } ?? false
        }
        native?.anchor = { [weak page] in page }
        pages[key] = page
        return page
    }

    func tabClosed(_ key: String) { close(key) }

    // MARK: Discard

    /// One minute hidden. The page's renderer holds the listed sites and usernames, so it does not
    /// outlive a short look away, as Chrome's password manager asks for the device owner again after
    /// its 60 s auth validity (`PasswordAccessAuthenticator::kAuthValidityPeriod`,
    /// password_access_authenticator.h). A revealed password is never in the renderer: it shows in
    /// the native reveal sheet (``NativePasswordSecretSurface``).
    static let hiddenPagePolicy = ContentDiscardPolicy.afterHidden(.seconds(60))

    func discardPolicy(for key: String) -> ContentDiscardPolicy { Self.hiddenPagePolicy }

    /// Nothing: no search, row or scroll of a secrets page is kept while it is gone.
    func saveViewState(for key: String, content: NSView) async -> ContentViewState { ContentViewState() }

    /// No picture either: the listing does not stay as a bitmap in the previews.
    func keepsDiscardPicture(for key: String) -> Bool { false }

    /// The tab's page went: its renderer, with the listing, ends now; the next show makes its own.
    func viewDiscarded(_ key: String) { close(key) }

    private func close(_ key: String) {
        guard let page = pages.removeValue(forKey: key) else { return }
        if let services { services.webUI.close(page) } else { page.close() }
    }

    /// The browser profiles in sidebar order (the default profile first when it leads).
    static func profiles(_ services: AppServices?) -> [PasswordsPageProvider.Profile] {
        guard let profiles = services?.browserProfiles else { return [] }
        return profiles.ordered.map { .init(id: $0.id, name: profiles.displayName($0.id)) }
    }
}
