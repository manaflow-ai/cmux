#if canImport(UIKit)
import Observation
import UIKit

/// UIKit view for the mirrored Mac browser frame and its input coordinator.
@MainActor
final class BrowserStreamSurfaceView: UIView {
    private let state: BrowserStreamSurfaceState
    private let contentView = BrowserStreamContentView(frame: .zero)
    private let coordinator: BrowserStreamSurfaceCoordinator

    init(state: BrowserStreamSurfaceState, actions: BrowserStreamSurfaceActions) {
        self.state = state
        coordinator = BrowserStreamSurfaceCoordinator(panelID: state.id, actions: actions)
        super.init(frame: .zero)
        accessibilityIdentifier = "BrowserStreamSurface"
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        coordinator.attach(to: contentView)
        observeState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func observeState() {
        withObservationTracking {
            _ = state.shouldFocusInput
            _ = state.latestFrame
            _ = state.pendingCommand
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyState()
                self.observeState()
            }
        }
        applyState()
    }

    private func applyState() {
        contentView.setInputFocused(state.shouldFocusInput)
        if let frame = state.latestFrame { contentView.display(frame) }
        if let command = state.consumeCommand() { coordinator.perform(command) }
    }
}
#endif
