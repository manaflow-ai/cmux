import AppKit

/// The All chats header row: the title (always shown: the collapsed section is this row alone)
/// and subtle icons (search, filter, group) that show only on hover while the section is open.
/// A click on the title or empty header space opens or closes the section; a hidden icon takes
/// no click. It stays in the accessibility tree. Its right-click menu is the section's.
final class SidebarChatsHeader: NSView {
    var onMenu: (() -> NSMenu?)?
    var onToggle: (() -> Void)?
    /// The icons show and take clicks.
    var iconsRevealed = false
    /// The views that are icons (hidden until revealed), and the open search field.
    var icons: [NSView] = []
    weak var searchField: NSView?

    override var isFlipped: Bool { true }

    /// One accessibility button named like the section: a press opens or closes it.
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(SidebarChatsView.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        let icon = icons.first { hit === $0 || hit.isDescendant(of: $0) }
        if icon != nil { return iconsRevealed ? hit : self }
        if let searchField, !searchField.isHidden, hit.isDescendant(of: searchField) { return hit }
        // The title and any other area toggle the section.
        return self
    }

    /// The first click in an inactive window opens the section (as the rows open chats).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onToggle?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?() ?? super.menu(for: event)
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }
}
