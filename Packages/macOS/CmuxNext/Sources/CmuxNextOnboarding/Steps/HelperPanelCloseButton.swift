import AppKit
import CmuxNextDesign

/// The drag panel's close button: an xmark that takes the first click, since the panel sits over System Settings while
/// cmux is in the background.
final class HelperPanelCloseButton: NSButton {
    private(set) lazy var hover = OnboardingHover(self, outset: NSSize(width: 4, height: 4))

    convenience init(target: AnyObject?, action: Selector?) {
        let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: OnboardingStrings.computerUseHelperClose) ?? NSImage()
        self.init(image: image, target: target, action: action)
        isBordered = false
        focusRingType = .none
        contentTintColor = Palette.textTertiary
        toolTip = OnboardingStrings.computerUseHelperClose
        hover.refresh(animated: false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        hover.layout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hover.state.hovering = true }
    override func mouseExited(with event: NSEvent) { hover.state.hovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hover.refresh(animated: false)
    }
}
