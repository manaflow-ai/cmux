import AppKit

@MainActor
final class ShortcutDiscoveryButtonView: NSButton, NSPopoverDelegate {
    private let popover = NSPopover()
    private var presented = false
    private var onPresentationChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let helpText = String(
            localized: "shortcutDiscovery.button.help",
            defaultValue: "Show all shortcuts"
        )
        title = ""
        image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "keyboard",
            pointSize: 11,
            weight: .medium
        )
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        isBordered = false
        focusRingType = .none
        toolTip = helpText
        target = self
        action = #selector(togglePopover)
        setAccessibilityLabel(helpText)
        setAccessibilityIdentifier("SidebarShortcutDiscoveryButton")

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if presented {
            showPopoverIfPossible()
        }
    }

    func update(isPresented: Bool, onPresentationChange: @escaping (Bool) -> Void) {
        self.onPresentationChange = onPresentationChange
        setPresented(isPresented, notifiesOwner: false)
    }

    func teardown() {
        popover.close()
        popover.contentViewController = nil
        onPresentationChange = nil
    }

    @objc private func togglePopover() {
        setPresented(!presented, notifiesOwner: true)
    }

    private func setPresented(_ value: Bool, notifiesOwner: Bool) {
        guard presented != value || (value && !popover.isShown) else { return }
        presented = value
        if value {
            showPopoverIfPossible()
        } else if popover.isShown {
            popover.close()
        }
        if notifiesOwner {
            onPresentationChange?(value)
        }
    }

    private func showPopoverIfPossible() {
        guard window != nil, !popover.isShown else { return }
        popover.contentViewController = AllShortcutsPopoverController()
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        guard presented else { return }
        presented = false
        onPresentationChange?(false)
    }
}
