import AppKit
import CmuxNextDesign

// Resizing the open All chats section from its top edge (Lawrence 2026-10-09): one third by
// default; a drag changes it, clamped between the header plus three rows and the sidebar minus
// the room the list above needs; remembered per Mac; a double-click resets to one third.
extension SidebarChatsView {
    public static var resizeLabel: String {
        String(localized: "sidebar.chats.resize", defaultValue: "Resize All chats", bundle: .module)
    }

    static let defaultShare: CGFloat = 1.0 / 3.0

    /// The share of `sidebarHeight` a section `height` tall takes, clamped: at least the header
    /// and three rows, at most the sidebar minus the room the rest needs (`reserved`).
    static func clampedShare(height: CGFloat, sidebarHeight: CGFloat, reserved: CGFloat) -> CGFloat {
        guard sidebarHeight > 0 else { return defaultShare }
        let minimum = Metrics.sidebarRowHeight * 4
        let maximum = max(minimum, sidebarHeight - reserved)
        return min(max(height, minimum), maximum) / sidebarHeight
    }

    /// The room the rest of the sidebar keeps: the titlebar, three list rows and the footer.
    static var reservedHeight: CGFloat { Metrics.titlebarHeight + Metrics.sidebarRowHeight * 5 }

    /// The sidebar this section is in (its height is the share's base); else its own window.
    var sidebarHeight: CGFloat {
        sequence(first: superview, next: { $0?.superview }).compactMap { $0 as? SidebarView }.first?.bounds.height
            ?? window?.contentView?.bounds.height ?? 0
    }

    func installDivider() {
        divider.onDragStart = { [weak self] in self?.dragStartHeight = self?.frame.height ?? 0 }
        divider.onDrag = { [weak self] delta in
            guard let self else { return }
            resize(toHeight: dragStartHeight - delta)
        }
        divider.onReset = { [weak self] in self?.setShare(nil) }
        divider.onStep = { [weak self] step in
            guard let self else { return }
            resize(toHeight: frame.height + CGFloat(step) * Metrics.sidebarRowHeight)
        }
        divider.valueDescription = { [weak self] in
            guard let share = self?.sidebarShare else { return nil }
            return "\(Int((share * 100).rounded()))%"
        }
        addSubview(divider)
    }

    /// Resizes the open section to `height` points (clamped) and remembers it.
    func resize(toHeight height: CGFloat) {
        setShare(Self.clampedShare(height: height, sidebarHeight: sidebarHeight, reserved: Self.reservedHeight))
    }

    /// A custom share (nil: back to one third); kept per Mac.
    func setShare(_ share: CGFloat?) {
        customShare = share
        if let share { defaults.set(Double(share), forKey: shareKey) } else { defaults.removeObject(forKey: shareKey) }
        onLayoutChange?()
    }
}
