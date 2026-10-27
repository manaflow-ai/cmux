import AppKit
import CmuxNextDesign

/// The app that gets the grant, as a tile to drag into a Privacy & Security
/// list: its icon and name, a hover fill, and a drag that carries the app's
/// file URL (what System Settings' lists accept).
final class PermissionAppTile: NSView, NSDraggingSource {
    private let appURL: URL
    /// The app's icon, read off the main thread by the App (cmux's own when it has none yet).
    private let appIcon: NSImage
    // wakeup-allow: bounded only while the permission card shows over System Settings with cmux in the background
    private lazy var hover = ChromeHover(self, tracking: .activeAlways)

    init(appURL: URL, icon: NSImage?) {
        self.appURL = appURL
        appIcon = icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: appIcon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: Self.displayName(appURL))
        name.font = .systemFont(ofSize: TypeScale.body, weight: TypeScale.emphasis)
        name.textColor = Palette.textPrimary
        let stack = NSStackView(views: [icon, name])
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32), icon.heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.displayName(appURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    /// The name Finder shows (localized, no extension).
    static func displayName(_ appURL: URL) -> String {
        let name = FileManager.default.displayName(atPath: appURL.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// The card floats over System Settings with cmux in the background: the first click starts the drag.
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
    override func mouseDown(with event: NSEvent) { hover.state.pressed = true }
    override func mouseUp(with event: NSEvent) { hover.state.pressed = false }

    override func mouseDragged(with event: NSEvent) {
        hover.state.pressed = false
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(NSRect(x: 10, y: (bounds.height - 32) / 2, width: 32, height: 32),
                              contents: appIcon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hover.refresh(animated: false)
    }
}
