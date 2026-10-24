import AppKit
import CmuxNextActions
import CmuxNextPages

extension PageDescriptor {
    /// The Mobile Pairing page (webviews/src/pages/mobile-pairing): cmux-page://cmux.mobile-pairing/.
    /// It reads the phone host's status and runs two actions: Sign In and Settings > Accounts.
    static let mobilePairing = PageDescriptor(
        id: "cmux.mobile-pairing", resource: "mobile-pairing", namespaces: ["cmux.mobilePairing."],
        nativeOps: [PageNativeOp.actionRun], actions: ["palette.auth.signIn", "accounts.show"])
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

    init(services: AppServices) {
        self.services = services
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
        guard let page = PageWebView(descriptor: .mobilePairing, routes: routes, errors: services.errorJournal.journal) else { return NSView() }
        native.anchor = { [weak page] in page }
        return page
    }
}
