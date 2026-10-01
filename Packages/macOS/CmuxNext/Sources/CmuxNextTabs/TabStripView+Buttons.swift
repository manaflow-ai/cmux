import AppKit
import CmuxNextDesign

// The trailing button group: layout at the strip's trailing edge, tooltips,
// and press tracking. Clicks go out as `TabStripIntent.trailingButton`.
extension TabStripView {
    /// Width reserved for the group (zero when it has no buttons).
    var trailingGroupWidth: CGFloat {
        TabStripButtonGroupView.width(for: model.trailingButtons.count, metrics: metrics)
    }

    func syncButtonGroup() {
        let buttons = model.trailingButtons
        buttonGroup.isHidden = buttons.isEmpty
        guard buttons != buttonGroup.buttons else { return }
        buttonGroup.setButtons(buttons)
        lastViewportWidth = -1
        needsLayout = true
    }

    /// Pins the group to the trailing edge and re-registers its tooltips.
    func layoutButtonGroup(width: CGFloat) {
        let padding = metrics.stripHorizontalPadding
        let frame = CGRect(x: max(0, bounds.width - padding - width), y: 0, width: width, height: bounds.height)
        if buttonGroup.frame != frame { buttonGroup.frame = frame }
        buttonGroup.layoutSubtreeIfNeeded()
        removeAllToolTips()
        for (button, rect) in zip(buttonGroup.buttons, buttonGroup.buttonFrames()) where !button.toolTip.isEmpty {
            addToolTip(buttonGroup.convert(rect, to: self), owner: button.toolTip as NSString, userData: nil)
        }
    }

    /// Index of the trailing button under `point` (strip coordinates).
    func trailingButtonIndex(at point: CGPoint) -> Int? {
        guard !buttonGroup.isHidden else { return nil }
        return buttonGroup.index(at: convert(point, to: buttonGroup))
    }

    /// While a button is pressed, keeps its pressed look only under the
    /// pointer. Returns whether a button press owns the drag.
    func trackTrailingButtonDrag(at point: CGPoint) -> Bool {
        guard let pressed = pendingTrailingPress else { return false }
        buttonGroup.pressedIndex = trailingButtonIndex(at: point) == pressed ? pressed : nil
        return true
    }

    /// Ends a button press; sends the intent when released on the same
    /// button. Returns whether a button press was active.
    func endTrailingButtonPress(at point: CGPoint) -> Bool {
        guard let pressed = pendingTrailingPress else { return false }
        pendingTrailingPress = nil
        buttonGroup.pressedIndex = nil
        if trailingButtonIndex(at: point) == pressed, let id = buttonGroup.id(at: pressed) {
            model.send(.trailingButton(id))
        }
        updateHover(at: point)
        return true
    }
}
