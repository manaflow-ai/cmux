import AppKit
import CmuxNextActions
import CmuxNextHibernation
import CmuxNextPages

extension PageDescriptor {
    /// The Mobile Pairing page (webviews/src/pages/mobile-pairing): cmux-page://cmux.mobile-pairing/.
    /// It reads the phone host's status and runs two actions: Sign In and Settings > Accounts.
    static let mobilePairing = PageDescriptor(
        id: "cmux.mobile-pairing", resource: "mobile-pairing", processGroup: .privileged, namespaces: ["cmux.mobilePairing."],
        nativeOps: [PageNativeOp.actionRun], actions: ["palette.auth.signIn", "accounts.show"],
        opTables: [PageOpTable(namespace: "cmux.mobilePairing.", read: ["status", "changes"], act: ["setAllowed"])])
}

extension InternalPageID {
    static let mobilePairing = InternalPageID(rawValue: "mobile-pairing")
}

/// Owns the Mobile Pairing page (plans/cmux-next/cloud-ios.md 2.2): a React page tab, one per
/// window, that walks the person through the v2 same-account pairing (sign in, phone access, the
/// listener) and shows this Mac's attach URL as a QR code for the iPhone camera.
/// `palette.mobileConnect` (palette, Window menu, `cmux cloud open-mobile-pairing`) shows it.
@MainActor
final class MobilePairingPageService: InternalPageProvider {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let page = MobilePairingPageService(services: context.services)
        context.services.pages.register(page) // at launch, so a restored tab finds it
        registry.bind("palette.mobileConnect", run: { invocation in
            try page.open(focus: invocation.allowsViewChange)
        })
    }

    private weak var services: AppServices?
    /// Each tab's page while it lives, with its `cmux.mobilePairing.` provider (for its keep reasons).
    private var pages: [String: (page: PageWebView, provider: MobilePairingPageProvider)] = [:]
    /// Opens a tab's page (default: `services.webUI`; tests pass their own engine).
    private let openPage: ((PageOpenRequest) -> PageWebView?)?

    init(services: AppServices, openPage: ((PageOpenRequest) -> PageWebView?)? = nil) {
        self.services = services
        self.openPage = openPage
    }

    /// Opens the page in the active window; automation (`focus` false) opens it without moving focus.
    func open(focus: Bool) throws {
        guard let services, let window = services.windows.active, services.pages.show(.mobilePairing, in: window, focus: focus) != nil else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
    }

    var page: InternalPageID { .mobilePairing }
    var title: String { MobilePairingStrings.pageTitle }
    var symbol: String { "iphone.radiowaves.left.and.right" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        let provider = MobilePairingPageProvider(services: services)
        let native = AppPageNativeProvider(services: services, page: .mobilePairing)
        let routes = [PageRoute(prefix: "cmux.mobilePairing.", provider: provider),
                      PageRoute(prefix: "cmux.app.", provider: native)]
        let request = PageOpenRequest(descriptor: .mobilePairing, routes: routes)
        guard let page = openPage?(request) ?? services.webUI.open(request) else { return NSView() }
        native.anchor = { [weak page] in page }
        pages[key] = (page, provider)
        return page
    }

    func tabClosed(_ key: String) { close(key) }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// Ten minutes hidden, as a browser tab (Chrome's proactive_discarding_policy.cc). A hidden
    /// page's code cannot be scanned, and the page reads the status and mints a code when it is
    /// made, so the code it showed is not worth its memory.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// A pairing step the person started in the page (Phone Access on or off) keeps it until it
    /// answers: a discard would cancel the call and the page that shows its end.
    func keepReasons(for key: String) -> [CannotDiscardReason] {
        (pages[key]?.provider.personCallsInFlight ?? 0) > 0 ? [.inProgress] : []
    }

    /// The tab stays and its page goes, closed as at ``tabClosed(_:)``.
    func viewDiscarded(_ key: String) { close(key) }

    /// Ends tab `key`'s page: its routes (the `changes` watch), bridge and engine page.
    private func close(_ key: String) {
        guard let page = pages.removeValue(forKey: key)?.page else { return }
        if let services { services.webUI.close(page) } else { page.close() }
    }
}
