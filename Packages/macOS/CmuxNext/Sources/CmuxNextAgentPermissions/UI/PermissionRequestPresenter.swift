public import AppKit
import CmuxNextCompat

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
        appURL: appURL))
    private let appURL: (PermissionKind) -> URL?
    private let guidedElsewhere: (PermissionKind) -> Bool
    private var following: Task<Void, Never>?
    /// The guide the person closed: the request still waits for its grant, the card stays hidden.
    private var closedGuide: String?

    /// - Parameters:
    ///   - requests: the request store.
    ///   - appURL: the app that gets a grant (cmux, or the Computer Use helper).
    ///   - guidedElsewhere: kinds another window guides after Continue (the
    ///     Computer Use window): the card hides while such a request is guided.
    ///   - screen: the screen to show the card on (cmux's key window's).
    public init(requests: AgentPermissionRequests, appURL: @escaping (PermissionKind) -> URL?,
                guidedElsewhere: @escaping (PermissionKind) -> Bool = { _ in false },
                screen: @escaping () -> NSScreen? = { NSApp.keyWindow?.screen ?? NSScreen.main }) {
        self.requests = requests
        self.appURL = appURL
        self.guidedElsewhere = guidedElsewhere
        self.screen = screen
    }

    /// Whether the card shows for `request` (nil: only the granted confirm).
    func showsCard(_ request: PendingPermissionRequest?, granted: PendingPermissionRequest?) -> Bool {
        if let request, request.phase == .guiding, request.id == closedGuide || guidedElsewhere(request.request.kind) { return false }
        // The granted confirm of a request another window guided: that window says so.
        if request == nil, let granted, guidedElsewhere(granted.request.kind) { return false }
        return request != nil || granted != nil
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
        guard showsCard(request, granted: granted) else { return panel.orderOut(nil) }
        panel.card.render(request, waiting: waiting, granted: granted)
        panel.present(on: screen())
    }

    private func closeGuide() {
        closedGuide = requests.current?.id
        panel.orderOut(nil)
    }
}
