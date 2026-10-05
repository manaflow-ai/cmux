import AppKit

/// Menus of the strip's trailing buttons (`TabStripButton.menu`): a click
/// opens a `.primary` button's menu, press-and-hold or right-click opens a
/// `.secondary` button's. The App builds each menu
/// (`TabContextTarget.trailingButton`); this anchors it under the button.
@MainActor
final class TabStripTrailingMenus {
    private weak var strip: TabStripView?
    /// Press-and-hold on a `.secondary` button opens its menu.
    private var holdTask: Task<Void, Never>?

    init(strip: TabStripView) {
        self.strip = strip
    }

    /// Mouse-down on button `index`: a `.primary` button opens its menu at
    /// once; any other is pressed until mouse-up, and a `.secondary` one
    /// opens its menu when held.
    func pressDown(_ index: Int) {
        guard let strip, let button = strip.buttonGroup.button(at: index) else { return }
        if button.menu == .primary { return show(at: index) }
        strip.pendingTrailingPress = index
        strip.buttonGroup.pressedIndex = index
        if button.menu == .secondary { startHold(index) }
    }

    /// Right-click on button `index`: its menu, anchored like the click or
    /// hold menu. Always nil, so AppKit shows no second menu.
    func showIfAny(at index: Int) -> NSMenu? {
        if let button = strip?.buttonGroup.button(at: index), button.menu != .none { show(at: index) }
        return nil
    }

    /// VoiceOver press: a `.primary` button opens its menu, any other runs.
    func press(_ id: String) {
        guard let strip, let index = strip.buttonGroup.buttons.firstIndex(where: { $0.id == id }) else { return }
        if strip.buttonGroup.buttons[index].menu == .primary { return show(at: index) }
        strip.model.send(.trailingButton(id))
    }

    /// Holding button `index` opens its menu instead of running it. A
    /// release first clears the press, so the task then does nothing.
    func startHold(_ index: Int) {
        holdTask?.cancel()
        guard let sleep = strip?.groups.sleep else { return }
        holdTask = Task { [weak self] in
            do { try await sleep(.milliseconds(450)) } catch { return }
            guard let self, !Task.isCancelled, let strip = self.strip, strip.pendingTrailingPress == index else { return }
            strip.pendingTrailingPress = nil
            strip.buttonGroup.pressedIndex = nil
            self.show(at: index)
        }
    }

    /// Button `index`'s menu under the button, from the App's provider.
    func show(at index: Int) {
        guard let strip, let id = strip.buttonGroup.id(at: index),
              let menu = strip.contextMenuProvider?(.trailingButton(id)), !menu.items.isEmpty else { return }
        strip.hoverCards.dismiss(.action)
        let frame = strip.convert(strip.buttonGroup.buttonFrames()[index], from: strip.buttonGroup)
        let origin = NSPoint(x: frame.minX, y: strip.isFlipped ? frame.maxY + 2 : frame.minY - 2)
        strip.beginMenuTracking(menu)
        menu.popUp(positioning: nil, at: origin, in: strip)
        strip.endMenuTracking()
    }
}
