import AppKit
import CmuxNextHibernation
import CmuxNextPhone

extension InternalPageID {
    static let phone = InternalPageID(rawValue: "phone")
}

/// The phone tab (plans/cmux-next/phone.md): one ``PhoneTabView`` per tab
/// over the app's one ``PhoneService``. Its route is the phone it shows
/// (`sim:<udid>`), so a reopened or relaunched tab shows the same phone.
@MainActor
final class PhonePageTab: InternalPageProvider {
    private let phones: PhoneService
    private var views: [String: PhoneTabView] = [:]
    private var routes: [String: PhoneDeviceID] = [:]
    /// The phone the next new tab shows (set by `phone.show` before it opens one).
    var nextDevice: PhoneDeviceID?

    init(phones: PhoneService) { self.phones = phones }

    var page: InternalPageID { .phone }
    var title: String { String(localized: "phone.tab.title", defaultValue: "Phone", table: "Phone", bundle: .module) }
    var symbol: String { "iphone" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let device: PhoneDeviceID?
        if let known = routes[key] {
            device = known
        } else {
            device = nextDevice
            nextDevice = nil
        }
        let view = PhoneTabView(service: phones, device: device)
        views[key] = view
        return view
    }

    func route(for key: String) -> String? { views[key]?.route ?? routes[key]?.description }

    func restore(_ route: String, for key: String) {
        if let id = PhoneDeviceID(route) { routes[key] = id }
    }

    func tabClosed(_ key: String) {
        views.removeValue(forKey: key)?.close()
        routes.removeValue(forKey: key)
    }

    // MARK: Discard (`memoryDiscardInternalPages`, p07-memory-028)

    /// Released at hide: its frames stop while it is hidden (``PhoneTabView``), so a hidden view
    /// shows nothing live, and the next one reads the phone again.
    static let hiddenPolicy = ContentDiscardPolicy.afterHidden(.zero)

    func discardPolicy(for key: String) -> ContentDiscardPolicy { Self.hiddenPolicy }

    /// Notes typed for the running recording and not sent live only in the view.
    func keepReasons(for key: String) -> [CannotDiscardReason] {
        views[key]?.hasUnsentNotes == true ? [.unsavedEdits] : []
    }

    /// The view's watches and stream end; the tab keeps the phone it showed.
    func viewDiscarded(_ key: String) {
        guard let view = views.removeValue(forKey: key) else { return }
        if let id = view.route.flatMap({ PhoneDeviceID($0) }) { routes[key] = id }
        view.close()
    }

    /// Some open phone tab (the page keeps one per window).
    var anyView: PhoneTabView? { views.values.first }

    /// The open tab showing `id`, if any.
    func view(showing id: PhoneDeviceID) -> PhoneTabView? {
        views.values.first { $0.route == id.description }
    }
}
