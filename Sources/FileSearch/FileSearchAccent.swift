import AppKit
import CmuxFoundation

/// Find's single source for the cmux accent (`app.accentColor`), followed
/// live through ``CmuxAccentColor/didChangeNotification``. Every accent Find
/// draws itself (match highlight, selected row, active option toggles) reads
/// it; native controls keep the system accent.
@MainActor
final class FileSearchAccent {
    private(set) var current: CmuxAccentColor
    private var observer: NSObjectProtocol?
    var onChange: (() -> Void)?

    init() {
        current = AppDelegate.shared?.accentColor ?? CmuxAccentColor()
        observer = NotificationCenter.default.addObserver(
            forName: CmuxAccentColor.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let accent = (notification.object as? CmuxAccentColorObserver)?.current,
                      accent != self.current else { return }
                self.current = accent
                self.onChange?()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The accent resolved for light or dark appearance.
    var color: NSColor { current.dynamicNSColor }
}

/// A results row whose selection is drawn with the cmux accent: strong
/// while the results have keyboard focus, a neutral tint otherwise.
@MainActor
final class FileSearchResultRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FileSearchResultRow")
    var accentColor: NSColor = CmuxAccentColor().dynamicNSColor {
        didSet { if isSelected { needsDisplay = true } }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 4, dy: 0)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let fill = isKeyboardFocused
            ? accentColor.withAlphaComponent(0.28)
            : NSColor.labelColor.withAlphaComponent(0.08)
        fill.setFill()
        path.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    private var isKeyboardFocused: Bool {
        guard let window, window.isKeyWindow else { return false }
        var view = superview
        while let candidate = view {
            if candidate is NSTableView { return window.firstResponder === candidate }
            view = candidate.superview
        }
        return false
    }
}
