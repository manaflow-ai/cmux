public import AppKit
import CmuxNextCompat
public import CmuxNextDesign

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
        appURL: appURL), theme: theme)
    private let theme: ThemeScope
    private let appURL: (PermissionKind) -> URL?
    private var following: Task<Void, Never>?
    /// The guide the person closed: the request still waits for its grant, the card stays hidden.
    private var closedGuide: String?

    /// - Parameters:
    ///   - requests: the request store.
    ///   - appURL: the app that gets a grant (cmux, or the Computer Use helper).
    ///   - theme: the scope the card draws in (the app's root: it belongs to no room).
    ///   - screen: the screen to show the card on (cmux's key window's).
    public init(requests: AgentPermissionRequests, appURL: @escaping (PermissionKind) -> URL?, theme: ThemeScope,
                screen: @escaping () -> NSScreen? = { NSApp.keyWindow?.screen ?? NSScreen.main }) {
        self.requests = requests
        self.theme = theme
        self.appURL = appURL
        self.screen = screen
    }

    /// Follows the store for the app's life. Idempotent.
    public func start() {
        guard following == nil else { return }
        let requests = requests
        // task-owner: follows the request store for the app's life.
        following = Task { [weak self] in
            for await state in ObservationStream({ (requests.current, requests.queued.count, requests.lastGranted) }) {
                self?.show(state.0, waiting: state.1, granted: state.2)
            }
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
