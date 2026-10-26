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
    /// Each tab's `cmux.mobilePairing.` provider while its page lives: it holds the code shown.
    private var providers: [String: MobilePairingPageProvider] = [:]
    /// The wall clock the codes' expiry is read on (tests set it).
    private let now: () -> Date

    init(services: AppServices, now: @escaping () -> Date = { Date() }) {
        self.services = services
        self.now = now
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
        guard let page = services.webUI.open(PageOpenRequest(descriptor: .mobilePairing, routes: routes)) else { return NSView() }
        native.anchor = { [weak page] in page }
        providers[key] = provider
        return page
    }

    func tabClosed(_ key: String) { providers[key] = nil }

    // MARK: Discard (`memoryDiscardInternalPages`, p07-memory-028)

    /// Ten minutes hidden, as a browser tab (Chrome's proactive_discarding_policy.cc), the life of
    /// the code it shows (``MobilePairingPageProvider/ticketLifetime``).
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// Pairing keeps the page: while the code it showed still works a phone may be scanning it, and a
    /// new page would show another code. The page reads the status again when it is made.
    func keepReasons(for key: String) -> [CannotDiscardReason] {
        Self.keepReasons(codeExpiresAt: providers[key]?.codeExpiresAt, now: now())
    }

    static func keepReasons(codeExpiresAt: Date?, now: Date) -> [CannotDiscardReason] {
        guard let codeExpiresAt, codeExpiresAt > now else { return [] }
        return [.inProgress]
    }

    func viewDiscarded(_ key: String) { providers[key] = nil }
}
