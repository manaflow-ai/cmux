import Combine
import Foundation

// Shared "which window's minimal-mode sidebar chrome is hovered" state.
// Written by the local event monitor in `WindowDecorationsController` and the
// drag-handle views; read by the titlebar accessory via the bridge publisher.
@MainActor @Observable final class MinimalModeSidebarChromeHoverState {
    static let shared = MinimalModeSidebarChromeHoverState()

    private(set) var hoveredWindowNumber: Int?
    @ObservationIgnored lazy var hoveredWindowNumberPublisher: AnyPublisher<Int?, Never> = observedValuesPublisher { [weak self] in self?.hoveredWindowNumber }

    private init() {}

    func setHovering(_ isHovering: Bool, windowNumber: Int) {
        if isHovering {
            guard hoveredWindowNumber != windowNumber else { return }
            hoveredWindowNumber = windowNumber
        } else if hoveredWindowNumber == windowNumber {
            hoveredWindowNumber = nil
        }
    }

    func clear() {
        guard hoveredWindowNumber != nil else { return }
        hoveredWindowNumber = nil
    }
}
