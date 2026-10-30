import AppKit
import CmuxNextDesign

/// The helper app as a row to drag into a Privacy & Security list, styled
/// like a row of that list: its small icon and name, a hover fill in the
/// row's shape, and a drag that carries the app's file URL (what System
/// Settings' lists accept). The panel lays its resting card under it.
final class HelperAppTile: NSView, NSDraggingSource {
    private let appURL: URL
    /// The helper's icon, read off the main thread by the App (cmux's own when it has none yet).
    private let appIcon: NSImage
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
    /// The icon's center from the row's leading edge (20 pt, as in System Settings' lists).
    static let iconCenter: CGFloat = inset + iconSide / 2
    // wakeup-allow: bounded only while the helper drag panel shows over System Settings with cmux in the background
    private(set) lazy var hover = ChromeHover(self, cornerRadius: HelperDragPanel.rowRadius, tracking: .activeAlways)
    /// Called when a drag of the app ended in another app (System Settings' list).
    var onDrop: (() -> Void)?
    /// The app's icon and name: the panel lines its arrow up over the icon and its text with the name.
    let icon: NSImageView
    let name: ChromeLabel
    /// The icon and the name together: the drag lifts them out of the row, which stays empty
    /// until the drag ends.
    private let content: NSStackView

    init(appURL: URL, icon: NSImage?) {
        self.appURL = appURL
        let appIcon = icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
        self.appIcon = appIcon
        let iconView = NSImageView(image: appIcon)
        self.icon = iconView
        name = OnboardingLabel.make(Self.displayName(appURL), font: Typography.system(size: TypeScale.body))
        content = NSStackView(views: [iconView, name])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        name.textColor = Palette.textPrimary
        let stack = content
        stack.spacing = Self.spacing
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSide), iconView.heightAnchor.constraint(equalToConstant: Self.iconSide),
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

    // input-coalesce: native (the first drag event starts an AppKit dragging session, which must start from that event and then tracks the pointer itself)
    // local-monitor-allow: begins a drag session, which AppKit starts only from a mouseDragged event; no hover work runs here
    override func mouseDragged(with event: NSEvent) {
        hover.state.pressed = false
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        // The whole row's content (icon and name) follows the pointer, as a row picked out of a list.
        item.setDraggingFrame(content.frame, contents: snapshot(of: content) ?? appIcon)
        beginDraggingSession(with: [item], event: event, source: self)
        content.alphaValue = 0
    }

    /// The view as an image, at the screen's scale.
    private func snapshot(of view: NSView) -> NSImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    override func mouseUp(with event: NSEvent) { hover.state.pressed = false }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        content.alphaValue = 1
        if !operation.isEmpty { onDrop?() }
    }

    // visibility-walk-allow: repaints its hover fill (ChromeHover) only, no layout
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hover.refresh(animated: false)
    }
}
