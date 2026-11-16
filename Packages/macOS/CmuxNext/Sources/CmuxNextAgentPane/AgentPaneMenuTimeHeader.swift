import AppKit
import CmuxNextDesign

/// The reply menu's date and time header ("Today, 1:06 PM"): it reads in the rows' own label color, and it
/// does nothing when clicked (Leo, 2026-11-15: "why on the ellipsis is the time gray? why not just have it be
/// white like the rest"; 2026-11-16: "why is the time still gray").
///
/// AppKit dims a disabled row's title whatever color its attributed title asks for (#43989 set labelColor
/// on a disabled row and it still drew gray), and an enabled row highlights and runs. So the row is a
/// view: AppKit draws a view row as the view draws itself, and a view row with no action neither highlights
/// nor runs. It stays disabled, so the keyboard skips it, and keeps the time as its title for VoiceOver.
@MainActor
enum AgentPaneMenuTimeHeader {
    static func item(_ time: String) -> NSMenuItem {
        let item = NSMenuItem(title: time, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = View(time)
        return item
    }

    /// One label in the menu font and label color, on the menu grid (MenuMetrics).
    final class View: NSView {
        /// The label starts on the rows' text column (every row of this menu has an icon), where AppKit drew
        /// the old disabled row's title; the height is a standard row's.
        static let leading = MenuMetrics.textX(iconColumn: true), trailing = MenuMetrics.trailing, height: CGFloat = 22

        let label: NSTextField

        init(_ time: String) {
            label = NSTextField(labelWithString: time)
            label.font = .menuFont(ofSize: 0)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityElement(false)
            let size = label.fittingSize
            super.init(frame: NSRect(x: 0, y: 0, width: Self.leading + ceil(size.width) + Self.trailing, height: Self.height))
            // The menu widens the row to its widest row; the label stays at the leading inset.
            autoresizingMask = [.width]
            label.frame.size = NSSize(width: ceil(size.width), height: ceil(size.height))
            // The cell pads its text; the text, not the field, starts on the column.
            let pad = label.cell?.titleRect(forBounds: label.bounds).minX ?? 0
            label.frame = NSRect(x: Self.leading - pad, y: ((Self.height - size.height) / 2).rounded(),
                                 width: ceil(size.width), height: ceil(size.height))
            label.autoresizingMask = [.width]
            addSubview(label)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(time)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}
