import AppKit

/// Menus of the strip's trailing buttons: a button that opens a menu
/// (`TabStripButton.opensMenu`, the overflow button) shows it on click and
/// right-click. The App builds each menu (`TabContextTarget.trailingButton`);
/// this anchors it under the button.
@MainActor
final class TabStripTrailingMenus {
    private weak var strip: TabStripView?

    init(strip: TabStripView) {
        self.strip = strip
    }

    /// Mouse-down on button `index`: a menu button opens its menu at once;
    /// any other is pressed until mouse-up.
    func pressDown(_ index: Int) {
        guard let strip, let button = strip.buttonGroup.button(at: index) else { return }
        if button.opensMenu { return show(at: index) }
        strip.pendingTrailingPress = index
        strip.buttonGroup.pressedIndex = index
    }

    /// Right-click on button `index`: its menu, anchored like the click
    /// menu. Always nil, so AppKit shows no second menu.
    func showIfAny(at index: Int) -> NSMenu? {
        if let button = strip?.buttonGroup.button(at: index), button.opensMenu { show(at: index) }
        return nil
    }

    /// VoiceOver press: a menu button opens its menu, any other runs.
    func press(_ id: String) {
        guard let strip, let index = strip.buttonGroup.buttons.firstIndex(where: { $0.id == id }) else { return }
        if strip.buttonGroup.buttons[index].opensMenu { return show(at: index) }
        strip.model.send(.trailingButton(id))
    }

    /// Ends a press without running it: a release, or the strip leaving its window.
    func endPress() {
        strip?.pendingTrailingPress = nil
        strip?.buttonGroup.pressedIndex = nil
    }

    /// Button `index`'s menu under the button, from the App's provider.
    func show(at index: Int) {
        guard let strip, strip.window != nil, let id = strip.buttonGroup.id(at: index),
              let menu = strip.contextMenuProvider?(.trailingButton(id)), !menu.items.isEmpty else { return }
        strip.hoverCards.dismiss(.action)
        let frame = strip.convert(strip.buttonGroup.buttonFrames()[index], from: strip.buttonGroup)
        let origin = NSPoint(x: frame.minX, y: strip.isFlipped ? frame.maxY + 2 : frame.minY - 2)
        strip.beginMenuTracking(menu)
        menu.popUp(positioning: nil, at: origin, in: strip)
        strip.endMenuTracking()
    }
}
