import AppKit
import CmuxNextDesign

/// The Home split's chat column: the page's chat (`content`, filling the column) with the chat's
/// compose button over its top-left at every list width, as in Messages (hidden only while the
/// New Message page is on screen). The button is the content's
/// sibling, so a conversation or the New Message page the page adds to `content` never covers it.
final class HomeChatColumnView: NSView {
    let content: NSView
    let compose: HomeChatComposeButton
    /// The compose button's left inset and its centre's distance from the top: the list header's
    /// row (`HomeSidebarHeaderLayout.band`), where the traffic lights sit.
    static let composeInset: CGFloat = 12
    static let composeCenterY: CGFloat = HomeSidebarHeaderLayout.band / 2

    init(content: NSView, compose: HomeChatComposeButton) {
        self.content = content
        self.compose = compose
        super.init(frame: content.frame)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        compose.isHidden = true
        addSubview(compose)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows the compose button (every list width; off while New Message is on screen).
    var showsCompose: Bool {
        get { !compose.isHidden }
        set {
            guard compose.isHidden == newValue else { return }
            compose.isHidden = !newValue
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        compose.frame = composeFrame
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        WindowControlsAvoiders.join(self)
    }

    /// At the column's top-left, or past the window's traffic lights where they lie over it: with
    /// the list folded and the sidebar hidden, this column is at the window's top-left (cmux#25593).
    private var composeFrame: NSRect {
        let side = HomeChatComposeButton.side
        let row = NSRect(x: 0, y: bounds.height - Self.composeCenterY - side / 2, width: bounds.width, height: side)
        let clearance = WindowTitlebar.windowControlsClearance(ofRow: row, in: self)
        return NSRect(x: max(Self.composeInset, clearance), y: row.minY, width: side, height: side)
    }

    /// Shown again (its workspace): the window's re-checks skipped it while hidden.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateWindowControlsAvoidance()
    }
}

// The window re-checks the compose button when the column moves in it with no resize.
extension HomeChatColumnView: WindowControlsAvoiding {
    func updateWindowControlsAvoidance() {
        guard !compose.isHidden, composeFrame != compose.frame else { return }
        needsLayout = true
    }
}
