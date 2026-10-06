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

    init(services: AppServices) {
        self.services = services
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.topPage.home")
        let home = services.home
        // task-owner: lives as long as this view; event-driven (Observation); ends once the chief mounts
        chiefObservation = Task { [weak self] in
            for await chief in Observations({ HomeChiefName.select(from: home.conversations)?.id }) {
                guard let self, let chief else { continue }
                mount(chief)
                return
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit { chiefObservation?.cancel() }

    private func mount(_ conversation: String) {
        guard let services else { return }
        let view = HomeHostView(services: services, conversation: conversation)
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        host = view
        services.home.homeDidOpen()
        // The page opened before the chief was known: give the box the keyboard now.
        if window?.firstResponder === window || window?.firstResponder == nil { focusPrimaryInput() }
    }

    /// Home's primary input (the message box) takes the keyboard.
    func focusPrimaryInput() {
        guard let target = host?.focusTarget else { return }
        window?.makeFirstResponder(target)
    }
}
