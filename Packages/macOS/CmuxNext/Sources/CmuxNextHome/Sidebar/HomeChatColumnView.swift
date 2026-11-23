import AppKit
import CmuxNextDesign

/// The Home split's chat column: the page's chat (`content`, filling the column) with the Chats
/// button (shows or folds the conversation list) and the chat's compose button over its top-left
/// at every list width, as in Messages (compose hides only while the New Message page is on
/// screen). The buttons are the content's siblings, so a conversation or the New Message page the
/// page adds to `content` never covers them.
final class HomeChatColumnView: NSView, WindowControlsAvoiding {
    let content: NSView
    let compose: HomeChatComposeButton
    let chats: HomeChatListButton
    /// The compose button's left inset and its centre's distance from the top: the list header's
    /// row (`HomeSidebarHeaderLayout.band`), where the traffic lights sit.
    static let composeInset: CGFloat = 12
    static let composeCenterY: CGFloat = HomeSidebarHeaderLayout.band / 2

    init(content: NSView, compose: HomeChatComposeButton, chats: HomeChatListButton = HomeChatListButton()) {
        self.content = content
        self.compose = compose
        self.chats = chats
        super.init(frame: content.frame)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        addSubview(chats)
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

    /// The button sits on the traffic lights' line (the list header's top row, `homeLightsRow`),
    /// lights over the column or not, so a toggle of the window's sidebar never moves it up or
    /// down. Under the lights (a folded list, or the chat at the window's left edge with the
    /// window's sidebar closed) it starts after them, as Messages' compose beside its lights;
    /// elsewhere it keeps its inset. In full screen (no lights) it is centred in the header's band.
    /// The traffic lights' row (its line) and what of them lies over the column, at its last layout.
    private var windowControls: (row: CGRect?, over: CGRect?)

    private var currentWindowControls: (row: CGRect?, over: CGRect?) {
        (homeLightsRow(band: HomeSidebarHeaderLayout.band), homeWindowControls(band: HomeSidebarHeaderLayout.band))
    }

    /// Relays out only when the traffic lights over the column changed (the page moved in its window).
    func updateWindowControlsAvoidance() {
        guard currentWindowControls != windowControls else { return }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        WindowControlsAvoiders.join(self)
        updateWindowControlsAvoidance()
    }

    /// A hidden workspace skipped window updates; re-read its position when shown.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateWindowControlsAvoidance()
    }

    override func layout() {
        super.layout()
        let side = HomeChatComposeButton.side
        var frame = NSRect(x: Self.composeInset, y: bounds.height - Self.composeCenterY - side / 2, width: side, height: side)
        windowControls = currentWindowControls
        if let line = windowControls.row { frame.origin.y = (line.midY - side / 2).rounded() }
        if let lights = windowControls.over, lights.minX < frame.maxX + Metrics.space3 {
            frame.origin.x = max(frame.minX, (lights.maxX + Metrics.space3).rounded(.up))
        }
        chats.frame = frame
        // Compose sits right of Chats, one gap apart, on the same line.
        compose.frame = frame.offsetBy(dx: side + Metrics.space2, dy: 0)
    }
}
