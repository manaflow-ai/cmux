import AppKit
import Observation

/// The Home top page: the chief conversation's native transcript
/// (`HomeHostView`), mounted once the owner lists the chief. The store's
/// home workspace and its chief tab stay as they are (other clients read
/// them); this page reads the same conversation through the same store.
@MainActor
final class TopHomePageView: NSView {
    private weak var services: AppServices?
    private(set) var host: HomeHostView?
    private var chiefObservation: Task<Void, Never>?
    /// The conversation the page shows now.
    private var mounted: String?

    init(services: AppServices) {
        self.services = services
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.topPage.home")
        let home = services.home
        // task-owner: lives as long as this view; event-driven (Observation). The chief placed
        // on a paired server (G6) replaces the local chief when it becomes known.
        chiefObservation = Task { [weak self] in
            for await chief in Observations({
                HomeChiefSource.choose(local: HomeChiefName.select(from: home.conversations)?.id, placed: home.cloudChief)
            }) {
                guard let self, let chief, chief != mounted else { continue }
                mount(chief)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit { chiefObservation?.cancel() }

    private func mount(_ conversation: String) {
        guard let services else { return }
        let hadFocus = host.map { window?.firstResponder === $0.focusTarget } ?? false
        host?.removeFromSuperview()
        let view = HomeHostView(services: services, conversation: conversation)
        mounted = conversation
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        host = view
        services.home.homeDidOpen()
        // The page opened before the chief was known: give the box the keyboard now.
        if hadFocus || window?.firstResponder === window || window?.firstResponder == nil { focusPrimaryInput() }
    }

    /// Home's primary input (the message box) takes the keyboard.
    func focusPrimaryInput() {
        guard let target = host?.focusTarget else { return }
        window?.makeFirstResponder(target)
    }
}
