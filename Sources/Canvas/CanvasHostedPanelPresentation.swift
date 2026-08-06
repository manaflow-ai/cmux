import AppKit
import Observation

@MainActor
@Observable
final class CanvasHostedPanelPresentation {
    private(set) var isFocused: Bool
    /// Whether the canvas shows multiple panes; drives the unfocused-split dim.
    private(set) var isSplit: Bool
    /// Panel appearance, refreshed on every host update so retained mounts
    /// track ghostty config reloads instead of the value captured at mount.
    private(set) var appearance: PanelAppearance
    private(set) var allowsPointerInput: Bool
    @ObservationIgnored private weak var pointerInputOwner: NSView?

    init(
        isFocused: Bool,
        isSplit: Bool,
        appearance: PanelAppearance,
        allowsPointerInput: Bool,
        pointerInputOwner: NSView
    ) {
        self.isFocused = isFocused
        self.isSplit = isSplit
        self.appearance = appearance
        self.allowsPointerInput = allowsPointerInput
        self.pointerInputOwner = pointerInputOwner
    }

    func setFocused(_ isFocused: Bool) {
        guard self.isFocused != isFocused else { return }
        self.isFocused = isFocused
    }

    /// Updates the split state when panes are added to or removed from the canvas.
    func setSplit(_ isSplit: Bool) {
        guard self.isSplit != isSplit else { return }
        self.isSplit = isSplit
    }

    /// Refreshes the appearance after a ghostty config reload.
    func setAppearance(_ appearance: PanelAppearance) {
        guard self.appearance != appearance else { return }
        self.appearance = appearance
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
