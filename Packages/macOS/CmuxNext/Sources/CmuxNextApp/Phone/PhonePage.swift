import AppKit
import CmuxNextHibernation
import CmuxNextPages
import CmuxNextPhone
import CmuxNextWakeups

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
    /// The phone each `phone.show` asked for (``show(_:_:)``), for the view of the tab it opened or selected.
    let opens = PageOpenRequests<PhoneDeviceID>()
    /// The windows' frame-aligned pointer input for the tabs' screens (feature `pointerFrameRemoteInput`),
    /// read when a tab's view is made: the page registers at launch, before features may be read.
    private let pointerFrames: @MainActor () -> FrameInputCoalescers?
    /// The app's main-thread scheduler and each tab's visibility node (`TabContentCache.node(for:)`), for the views.
    private let mainWork: MainWorkScheduler
    private let nodes: @MainActor (String) -> VisibilityNode

    init(phones: PhoneService, mainWork: MainWorkScheduler, nodes: @escaping @MainActor (String) -> VisibilityNode,
         pointerFrames: @escaping @MainActor () -> FrameInputCoalescers? = { nil }) {
        self.phones = phones
        self.mainWork = mainWork
        self.nodes = nodes
        self.pointerFrames = pointerFrames
    }

    var page: InternalPageID { .phone }
    var title: String { String(localized: "phone.tab.title", defaultValue: "Phone", table: "Phone", bundle: .module) }
    var symbol: String { "iphone" }

    /// Shows `device` in the tab `show` opens or selects (`phone.show`): a view made now opens on it,
    /// a tab with no view yet shows it at its first show, and a shown tab switches to it.
    func show(_ device: PhoneDeviceID, _ show: () -> InternalPageView?) -> InternalPageView? {
        let shown = opens.open(device, show)
        if let shown, shown.isBuilt { views[shown.key]?.select(device) }
        return shown
    }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        // The tab's own request is newer than its route; a rebuilt tab never takes another tab's.
        let device = opens.take(for: key) ?? routes[key] ?? opens.running
        let view = PhoneTabView(service: phones, device: device, node: nodes(key), mainWork: mainWork)
        view.pointerFrames = pointerFrames()
        views[key] = view
        return view
    }

    func route(for key: String) -> String? { views[key]?.route ?? (opens.kept(for: key) ?? routes[key])?.description }

    func restore(_ route: String, for key: String) {
        if let id = PhoneDeviceID(route) { routes[key] = id }
    }

    func tabClosed(_ key: String) {
        views.removeValue(forKey: key)?.close()
        routes.removeValue(forKey: key)
        opens.forget(key)
    }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// Released once hidden 20 s, as a hidden Mac screen ends its session: its frames stop at hide
    /// (``PhoneTabView``), and switching tabs back and forth keeps the view and runs no `xcrun` on
    /// show. Chrome discards nothing at hide either (proactive_discarding_policy.cc waits a minimum
    /// hidden time).
    static let hiddenPolicy = ContentDiscardPolicy.afterHidden(.seconds(20))

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
}
