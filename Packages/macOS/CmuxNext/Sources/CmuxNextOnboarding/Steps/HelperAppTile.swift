import AppKit
import CmuxNextDesign

/// The helper app as a row to drag into a Privacy & Security list, styled
/// like a row of that list: its small icon and name, a hover fill in the
/// row's shape, and a drag that carries the app's file URL (what System
/// Settings' lists accept). The panel lays its resting card under it.
final class HelperAppTile: NSView, NSDraggingSource {
    private let appURL: URL
    /// The app icon's side in points.
    static let iconSide: CGFloat = 24
    /// The row's height, as a row of System Settings' app lists.
    static let height: CGFloat = 36
    /// The icon's inset from the row's leading edge.
    private static let inset: CGFloat = 8
    /// Room between the icon and the name.
    private static let spacing: CGFloat = 8
    /// Where the name starts, from the row's leading edge.
    static let nameInset: CGFloat = inset + iconSide + spacing
    private(set) lazy var hover = ChromeHover(self, cornerRadius: HelperDragPanel.rowRadius)
    /// Called when a drag of the app ended in another app (System Settings' list).
    var onDrop: (() -> Void)?
    /// The app's icon and name: the panel lines its arrow up over the icon and its text with the name.
    let icon: NSImageView
    let name: ChromeLabel

    init(appURL: URL) {
        self.appURL = appURL
        icon = NSImageView(image: NSWorkspace.shared.icon(forFile: appURL.path))
        name = OnboardingLabel.make(Self.displayName(appURL), font: Typography.system(size: TypeScale.body))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.textColor = Palette.textPrimary
        let stack = NSStackView(views: [icon, name])
        stack.spacing = Self.spacing
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSide), icon.heightAnchor.constraint(equalToConstant: Self.iconSide),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.inset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.displayName(appURL))
    }

    /// The name Finder shows (localized, no extension).
    static func displayName(_ appURL: URL) -> String {
        let name = FileManager.default.displayName(atPath: appURL.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// The panel sits over System Settings with cmux in the background:
    /// the first click must start the drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

    override func mouseDown(with event: NSEvent) {
        hover.state.pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        hover.state.pressed = false
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let side = Self.iconSide
        item.setDraggingFrame(NSRect(x: Self.inset, y: (bounds.height - side) / 2, width: side, height: side), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { hover.state.pressed = false }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if !operation.isEmpty { onDrop?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hover.refresh(animated: false)
    }
}
