import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The drag panel's back button: a chevron in a small circle with the shared
/// hover fill, taking the first click. It closes the panel and brings the
/// Computer Use window back. The panel puts a round `OnboardingCardView`
/// under it (`makeCircle(mainWork:)`), so it rests like the helper's row. The panel sits
/// over System Settings while cmux is in the background, so its hover tracks
/// in any window, not only the key one.
final class HelperPanelBackButton: NSButton {
    /// The circle's diameter.
    static let side: CGFloat = 28
    // The button draws its chevron in its own layer: the fill is that layer's background, under it.
    // wakeup-allow: bounded only while the helper drag panel shows over System Settings with cmux in the background
    private(set) lazy var hover = ChromeHover(self, cornerRadius: Self.side / 2, behindContent: true, tracking: .activeAlways)

    convenience init(target: AnyObject?, action: Selector?) {
        let image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: OnboardingStrings.back) ?? NSImage()
        self.init(image: image, target: target, action: action)
        isBordered = false
        focusRingType = .none
        imagePosition = .imageOnly
        symbolConfiguration = .init(pointSize: 12, weight: TypeScale.emphasis)
        contentTintColor = Palette.textSecondary
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(OnboardingStrings.back)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side), heightAnchor.constraint(equalToConstant: Self.side),
        ])
        hover.refresh(animated: false)
    }

    /// The resting circle to lay under the button; `mainWork` repaints it on a theme change.
    static func makeCircle(mainWork: MainWorkScheduler) -> NSView { OnboardingCardView(cornerRadius: side / 2, mainWork: mainWork) }

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

    // visibility-walk-allow: repaints its hover fill (ChromeHover) only, no layout
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hover.refresh(animated: false)
    }
}
