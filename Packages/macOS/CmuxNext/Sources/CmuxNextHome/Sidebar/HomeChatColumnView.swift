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
    /// The Chats button's left inset from the column's edge: Messages' compose sits 8 pt right of
    /// its list's edge (the user, 2026-11-23: "make spacing here aligned (imessage sidebar +
    /// imessage compose button)").
    static let composeInset: CGFloat = 8
    /// The gap between Chats and compose, and between the traffic lights (with the titlebar
    /// accessory after them) and Chats: macOS 26's gap between two separate glass toolbar items
    /// (8 pt in both its regular and compact toolbars).
    static let buttonGap: CGFloat = 8
    /// The buttons' centre's distance from the top with no traffic lights (full screen): the
    /// middle of the list header's row (`HomeSidebarHeaderLayout.band`).
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

    /// The line from the lights' row (else, in full screen, the toolbar band's own line), and what to
    /// keep clear of: the lights and the band at its fully open width (`homeTopRowReserve`), never
    /// its width of the moment, so the corner hover never moves the buttons.
    private var currentWindowControls: (row: CGRect?, over: CGRect?) {
        let reserve = homeTopRowReserve(band: HomeSidebarHeaderLayout.band)
        return (homeLightsRow(band: HomeSidebarHeaderLayout.band) ?? reserve?.line, reserve?.clear)
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
        windowControls = currentWindowControls
        let frames = Self.buttonFrames(height: bounds.height, row: windowControls.row, over: windowControls.over,
                                       scale: window?.backingScaleFactor ?? 2)
        chats.frame = frames.chats
        compose.frame = frames.compose
    }

    /// Chats and compose in a column `height` tall (unflipped): one size, ``buttonGap`` apart, centred
    /// on the traffic lights' line (`row`) to the backing pixel, as Messages centres its compose on its
    /// lights. Whole-point rounding put them half a point above the lights when the line fell on a half
    /// point. Chats starts ``composeInset`` in, or ``buttonGap`` after the lights and the accessory when
    /// they lie over the column (`over`). With no lights (full screen) they are centred in the header's band.
    static func buttonFrames(height: CGFloat, row: CGRect?, over: CGRect?, scale: CGFloat) -> (chats: NSRect, compose: NSRect) {
        let s = max(scale, 1)
        let side = HomeChatComposeButton.side
        // On the lights' line only when the lights lie over the column (the buttons sit beside them,
        // as Messages' compose). Elsewhere (the chat right of the list or a pane's strip) they are
        // centred in the header's band, 11 pt from the top: on the lights' line they sat 6 pt from
        // the edge (the person, 2026-11-26: "we still need padding above the imessage
        // compose/sidebar buttons ... ideally center it").
        let midY = (over != nil ? row?.midY : nil) ?? height - composeCenterY
        var frame = NSRect(x: composeInset, y: ((midY - side / 2) * s).rounded() / s, width: side, height: side)
        if let lights = over, lights.minX < frame.maxX + buttonGap {
            frame.origin.x = max(frame.minX, ((lights.maxX + buttonGap) * s).rounded(.up) / s)
        }
        return (frame, frame.offsetBy(dx: side + buttonGap, dy: 0))
    }
}
