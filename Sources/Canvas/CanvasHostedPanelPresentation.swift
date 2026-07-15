import AppKit
import Observation

@MainActor
@Observable
final class CanvasHostedPanelPresentation {
    private(set) var allowsPointerInput: Bool
    @ObservationIgnored private weak var pointerInputOwner: NSView?

    init(allowsPointerInput: Bool, pointerInputOwner: NSView) {
        self.allowsPointerInput = allowsPointerInput
        self.pointerInputOwner = pointerInputOwner
    }

    func setAllowsPointerInput(_ allowsPointerInput: Bool) {
        guard self.allowsPointerInput != allowsPointerInput else { return }
        self.allowsPointerInput = allowsPointerInput
    }

    func acceptsPointerEntryEvent(_ event: NSEvent) -> Bool {
        guard let owner = pointerInputOwner,
              let window = owner.window,
              event.window === window,
              let contentView = window.contentView else { return false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(point) else { return false }
        return hitView === owner || hitView.isDescendant(of: owner)
    }
}
