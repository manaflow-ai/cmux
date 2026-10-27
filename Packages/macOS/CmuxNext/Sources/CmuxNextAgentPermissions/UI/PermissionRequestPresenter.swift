public import AppKit
import CmuxNextCompat
public import CmuxNextWakeups

/// Shows the permission card while a request waits: follows
/// ``AgentPermissionRequests`` and draws its ``AgentPermissionRequests/current``
/// in one ``PermissionRequestPanel``; hides it when none waits.
///
/// The card's presses go back to the request store, the one mutation path.
@MainActor
public final class PermissionRequestPresenter {
    private let requests: AgentPermissionRequests
    private let screen: () -> NSScreen?
    private lazy var panel = PermissionRequestPanel(card: PermissionRequestCardView(
        actions: .init(deny: { [weak self] in self?.requests.denyCurrent() },
                       proceed: { [weak self] in self?.requests.continueCurrent() },
                       close: { [weak self] in self?.closeGuide() }),
        appURL: appURL, appIcon: appIcon))
    private let appURL: (PermissionKind) -> URL?
    private let appIcon: (PermissionKind) -> NSImage?
    private let mainWork: MainWorkScheduler
    private var following: ServiceObservation<Shown>?
    /// The guide the person closed: the request still waits for its grant, the card stays hidden.
    private var closedGuide: String?

    /// - Parameters:
    ///   - requests: the request store.
    ///   - appURL: the app that gets a grant (cmux, or the Computer Use helper).
    ///   - appIcon: that app's icon, read off the main thread (nil until it is).
    ///   - screen: the screen to show the card on (cmux's key window's).
    ///   - mainWork: the app's one main-thread scheduler: the card follows the store on it.
    public init(requests: AgentPermissionRequests, appURL: @escaping (PermissionKind) -> URL?,
                appIcon: @escaping (PermissionKind) -> NSImage?,
                screen: @escaping () -> NSScreen? = { NSApp.keyWindow?.screen ?? NSScreen.main },
                mainWork: MainWorkScheduler) {
        self.requests = requests
        self.appURL = appURL
        self.appIcon = appIcon
        self.screen = screen
        self.mainWork = mainWork
    }

    /// What the card shows: the request, how many wait behind it and the last grant.
    struct Shown: Equatable {
        var request: PendingPermissionRequest?
        var waiting: Int
        var granted: PendingPermissionRequest?
    }

    /// Follows the store for the app's life. Idempotent.
    ///
    /// A service observation, not a view's: it orders the card's own panel in and out, so it runs with no cmux
    /// window on screen (the card floats over System Settings). `visible`: an agent's request shows the card; the
    /// person's Deny or Continue flushes before its frame.
    public func start() {
        guard following == nil else { return }
        let requests = requests
        following = ServiceObservation(.visible, owner: "PermissionRequestPresenter.card", on: mainWork) {
            Shown(request: requests.current, waiting: requests.queued.count, granted: requests.lastGranted)
        } apply: { [weak self] shown in
            self?.show(shown.request, waiting: shown.waiting, granted: shown.granted)
        }
    }

    private func show(_ request: PendingPermissionRequest?, waiting: Int, granted: PendingPermissionRequest?) {
        if let request, request.id == closedGuide, request.phase == .guiding { return panel.orderOut(nil) }
        guard request != nil || granted != nil else { return panel.orderOut(nil) }
        panel.card.render(request, waiting: waiting, granted: granted)
        panel.present(on: screen())
    }

    private func closeGuide() {
        closedGuide = requests.current?.id
        panel.orderOut(nil)
    }
}
