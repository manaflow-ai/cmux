import Foundation
import Observation

/// Re-runs `render` whenever an observable property it read changes; changes
/// in one main-actor turn coalesce into one render.
final class HomeObservationLoop {
    private let render: () -> Void
    private var isActive = true

    init(_ render: @escaping () -> Void) {
        self.render = render
        arm()
    }

    func cancel() { isActive = false }

    private func arm() {
        guard isActive else { return }
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            // task-owner: one hop back to the main actor to re-arm; dropped when the loop is released
            Task { @MainActor in self?.arm() }
        }
    }
}
