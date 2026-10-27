import AppKit

/// MessagesLab 69f4256's context menu and picker chrome (Host.swift, not
/// vendored), for the pane controller: the real menu order (Tapback
/// Details…, Reply…, Attach Sticker…; Copy; Share…; Delete…), the target
/// bubble's highlight while the menu is open, the pressed bubble lifted
/// above the picker's dim, and the picker's emoji bubble. The differences
/// from Host.swift are marked `cmux:`.
extension ChatController {
    // MARK: Context menu

    @MainActor func menu(at p: CGPoint) -> NSMenu? {
        guard let hit = demo?.hit(p) else { return previewMenu(at: p) }
        let ref = hit.row.ref
        let content = contentMenu
        let current = hit.row.reactions.first { $0.senderId == store?.state.me }?.kind
        let menu = NSMenu()
        // The pressed bubble is highlighted while the menu is open (real Messages, macOS 27:
        // incoming 59 -> 98, outgoing (72,147,247) -> (45,89,192), in about 0.2 s from
        // the press; back when the menu closes).
        // The drawn balloon with its frame's corners (MessagesLab 2281879 RowDraw.balloon).
        // MessagesLab 267d218: a 1-line text ends in half circles; 7924f00: my text balloon's soft edge (soft-copies).
        let hl = MenuHighlight(host: host, shape: BubblePath.balloon(drawn: hit.outline, frameSize: hit.body.size, row: hit.row).cgPath,
                               outgoing: hit.row.outgoing, soft: demo?.softMask(hit),
                               scale: demo?.renderScale ?? Fixture.renderScale, softOwner: demo?.softMaskOwner(hit),
                               anchor: demo?.highlightAnchor(hit), space: demo?.layer)
        menu.delegate = hl
        menuHighlight = hl
        hl.start()
        // cmux: a path link (an agent's `file:///…`) leads with the host's file menu (Open in Right
        // Pane, Open With, Reveal, Copy Path, Quick Look, Share).
        if let fileHost, let link = linkURL(at: p), link.isFileURL, link.path.hasPrefix("/") {
            let file = URL(fileURLWithPath: link.path)
            fileHost.menuItems(forFileNamed: file.lastPathComponent) { file }.forEach(menu.addItem)
            menu.addItem(.separator())
        }
        // cmux: a link under the pointer (in text or a card): Open Link and Copy Link Address lead.
        if let link = linkURL(at: p), !link.isFileURL {
            content.linkItems(link).forEach(menu.addItem)
            menu.addItem(.separator())
        }
        // cmux: tapbacks only while the owner takes them (`canReact`, false offline).
        let canReact = intents?.canReact == true
        if canReact {
            // MessagesLab 7518134: timed from the choosing input (PaneTapback.swift).
            TapbackMenuRows.items(current: current, react: { [weak self] in self?.chooseTapback(ref, $0) },
                                  emojiPicker: { [weak self] in self?.showEmojiPicker() }).forEach(menu.addItem)
        }
        // Then (real order, macOS 27): Tapback Details…, Reply…, Attach Sticker…; Edit
        // (mine); Copy; Share…; Delete…, with separators between the groups.
        menu.addItem(MenuAction(title: Strings.menuTapbackDetails, symbol: "plus.magnifyingglass") { [weak self] in self?.showTapbackDetails(hit) })
        // cmux: Reply… only when the owner can take a reply (HomeOp has none yet, as SwipeReply).
        if intents?.canReply == true {
            // cmux: Reply to Selection (plans/cmux-next/reply-to-selection-DESIGN.md): text selected in this
            // message is the reply's quote; Reply… still answers the whole message.
            if let quote = selectionQuote(at: hit) {
                menu.addItem(MenuAction(title: CmuxStrings.replyToSelection, symbol: "text.quote") { [weak self] in self?.replyToSelection(quote) })
            }
            menu.addItem(MenuAction(title: Strings.menuReplyEllipsis, symbol: "arrowshape.turn.up.left") { [weak self] in self?.dispatch(.reply(ref)); self?.focusCompose() })
        }
        // Attach Sticker…: opens the tapback picker with its emoji (no image stickers).
        if canReact {
            menu.addItem(MenuAction(title: Strings.menuAttachSticker, symbol: MenuSymbols.attachSticker) { [weak self] in self?.showPicker(for: hit) })
        }
        menu.addItem(.separator())
        // cmux: no Edit or Undo Send (HomeOp has no edit or unsend).
        // cmux: Copy copies the words selected in this message, else the whole message; a link card's
        // address and a place's coordinates copy the same way (HomeContentMenu).
        let selected = selectionQuote(at: hit) != nil ? selection.selectedText : nil
        switch hit.row.part {
        case .text, .link, .location:
            content.partItems(hit.row.part, selection: selected, links: false,
                              resolve: { _ in { nil } }, openAttachment: { _ in }).forEach(menu.addItem)
        default: break
        }
        // cmux: the message's permalink, the form the Channels page copies (conversation-link-resolve opens it).
        if let link = intents?.messageLink(ref.messageId) {
            menu.addItem(MenuAction(title: CmuxStrings.copyLink, symbol: "link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) })
        }
        // cmux: Forward… (u5402): the text goes to another chat or agent the host asks for.
        if case let .text(text, _) = hit.row.part, intents?.canForward == true {
            menu.addItem(MenuAction(title: CmuxStrings.forward, symbol: "arrowshape.turn.up.right") { [weak self] in self?.intents?.forward(text) })
        }
        if menu.items.last.map({ !$0.isSeparatorItem }) == true { menu.addItem(.separator()) }
        // cmux: a video plays in place; opening it in an app is only here.
        if case let .attachment(a) = hit.row.part {
            if a.kind == "video", let intents {
                let playing = intents.videoState(ref) == .playing
                menu.addItem(MenuAction(title: playing ? CmuxStrings.pauseVideo : CmuxStrings.playVideo,
                                        symbol: playing ? "pause.fill" : "play.fill") { [weak self] in self?.intents?.toggleVideo(ref, a.id) })
            }
            content.attachmentItems(name: a.fileName, resolve: attachmentResolver(ref.messageId, a.id)) { [weak self] in
                self?.intents?.openAttachment(ref.messageId, a.id)
            }.forEach(menu.addItem)
            menu.addItem(.separator())
        }
        // cmux: my "Not Delivered" message: Try Again and Delete (Messages' pair); else lane 16's
        // Cancel Upload, only while the send can be cancelled.
        if intents?.canRetrySend(ref.messageId) == true {
            menu.addItem(MenuAction(title: CmuxStrings.tryAgain, symbol: "arrow.clockwise") { [weak self] in self?.intents?.retrySend(ref.messageId) })
            menu.addItem(MenuAction(title: CmuxStrings.deleteFailed, symbol: "trash") { [weak self] in self?.intents?.deleteFailedSend(ref.messageId) })
            menu.addItem(.separator())
        } else if intents?.canCancelSend(ref.messageId) == true {
            menu.addItem(MenuAction(title: CmuxStrings.cancelUpload, symbol: "xmark.circle") { [weak self] in self?.intents?.cancelSend(ref.messageId) })
            menu.addItem(.separator())
        }
        if !Self.shareItems(hit).isEmpty {
            menu.addItem(MenuAction(title: Strings.menuShare, symbol: "square.and.arrow.up") { [weak self] in self?.share(hit) })
        }
        // cmux: no Delete…: MessagesLab's `.delete` hides the message on this device, and
        // HomeStore has no local hide (HomeOp has no delete), so nothing could honour it.
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }

    // MARK: Shared content rows (HomeContentMenu)

    /// The builder of this pane's content rows: links open through the host (app links and paths to
    /// `onAppLink`), files through the host's file menu, Save As… as a sheet on this window.
    @MainActor var contentMenu: HomeContentMenu {
        HomeContentMenu(openLink: { [weak self] url in
            guard let self else { return }
            if url.isCmuxAppLink || url.isHomePathLink { onAppLink?(url) } else { onOpenLink(url, false) }
        }, attachmentRows: HomeAttachmentRows(window: host.window), fileHost: fileHost)
    }

    /// Fetches the local copy of attachment `id` of message `message` when a row runs.
    @MainActor func attachmentResolver(_ message: ID, _ id: ID) -> @MainActor @Sendable () async -> URL? {
        { [weak self] in await self?.intents?.attachmentFile(message, id) }
    }

    /// The menu of a quoted reply's preview under `p`, which is not a bubble (the quoted root drawn
    /// above a reply: a text card, a picture, a link): the quoted part's own rows. Nil elsewhere.
    @MainActor func previewMenu(at p: CGPoint) -> NSMenu? {
        guard let demo else { return nil }
        for case let cell as RowCell in demo.collection.visibleCells {
            guard let spec = cell.spec, case let .threadPreview(pv) = spec.kind, let part = pv.part else { continue }
            let r = cell.convert(cell.bounds, to: demo)
            guard r.contains(p) else { continue }
            let width = max(pv.box.width, 90)
            let inside = pv.outgoing ? p.x >= r.minX + spec.metrics.rightEdge - width : p.x <= r.minX + Fixture.leftEdge + width
            guard inside else { continue }
            let root = pv.root
            let rows = contentMenu.partItems(part, resolve: { [weak self] a in
                self?.attachmentResolver(root.messageId, a.id) ?? { nil }
            }, openAttachment: { [weak self] a in self?.intents?.openAttachment(root.messageId, a.id) })
            guard !rows.isEmpty else { return nil }
            let menu = NSMenu()
            rows.forEach(menu.addItem)
            return menu
        }
        return nil
    }

    // MARK: Menu actions

    /// Tapback Details…: who reacted, with what (a popover at the bubble).
    /// cmux: names from the HomeStore conversation's participants.
    func showTapbackDetails(_ hit: MessagesWindowView.Hit) {
        guard let st = store?.state else { return }
        let lines = hit.row.reactions.map { r -> String in
            let who = st.conversation.participants.first { $0.id == r.senderId }?.displayName ?? r.senderId
            let what: String
            switch r.kind {
            case let .tapback(t): what = TapbackGlyph.emoji(t) ?? Strings.tapbackName(t)
            case let .emoji(e): what = e
            }
            return "\(what)  \(who)"
        }
        let text = NSTextField(wrappingLabelWithString: lines.isEmpty ? Strings.tapbackDetailsNone : lines.joined(separator: "\n"))
        text.font = .systemFont(ofSize: 13)
        let title = NSTextField(labelWithString: Strings.tapbackDetailsTitle)
        title.font = .boldSystemFont(ofSize: 13)
        let stack = NSStackView(views: [title, text])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let vc = NSViewController()
        vc.view = stack
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.show(relativeTo: hit.body, of: host, preferredEdge: .maxY)
    }

    /// Share…: the system share picker with the message's text or link.
    /// cmux: attachments are shared from their own app (Open in Default App);
    /// their bytes are HomeStore's, not a fixture file.
    static func shareItems(_ hit: MessagesWindowView.Hit) -> [Any] {
        switch hit.row.part {
        case let .text(t, _): return [t]
        case let .link(url, _, _, _, _): return [URL(string: url)].compactMap { $0 }
        default: return []
        }
    }

    func share(_ hit: MessagesWindowView.Hit) {
        let items = Self.shareItems(hit)
        guard !items.isEmpty else { return }
        NSSharingServicePicker(items: items).show(relativeTo: hit.body, of: host, preferredEdge: .minY)
    }

    // MARK: Picker chrome

    /// The pressed bubble's outline in the host's coordinates: the picker's dim leaves it out, so the
    /// real bubble stays bright (real Messages lifts it). The drawn balloon with its frame's corners, as
    /// the menu highlight's shape. No bitmap copy of the row: a copy over the dim took its orientation
    /// from the flips of the views above it and drew upside down in a cmux-next pane (Lawrence 2026-10-20).
    func pickerHole(for hit: MessagesWindowView.Hit) -> CGPath {
        BubblePath.balloon(drawn: hit.outline, frameSize: hit.body.size, row: hit.row).cgPath
    }

    /// The emoji button: a glass circle 34 pt under the strip (center 95 pt in, 12 pt
    /// below it) with two small trailing dots, as a thought bubble.
    func pickerEmojiButton(under p: NSView) -> NSView {
        EmojiBubbleButton(frame: CGRect(x: p.frame.minX + 95 - 17, y: p.frame.maxY + 12 - 17, width: 34, height: 34)) { [weak self] in
            self?.closePicker(); self?.showEmojiPicker()
        }
    }
}

/// The tapback picker's emoji button: a glass circle with a smiley and two trailing dots.
final class EmojiBubbleButton: NSView {
    private let run: () -> Void
    init(frame: CGRect, run: @escaping () -> Void) {
        self.run = run
        super.init(frame: frame.insetBy(dx: 0, dy: 0).union(CGRect(x: frame.minX, y: frame.minY, width: frame.width + 20, height: frame.height + 22)))
        let glass = LabGlass.surface(frame: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        glass.cornerRadius = frame.width / 2
        let img = NSImageView(image: NSImage(systemSymbolName: "face.smiling", accessibilityDescription: Strings.menuAttachSticker)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular)) ?? NSImage())
        img.contentTintColor = NSColor(white: 0.62, alpha: 1)
        img.frame = glass.bounds
        glass.contentView = img
        addSubview(glass)
        for (cx, cy, d) in [(frame.width / 2 + 10, frame.height + 6, 6.0), (frame.width / 2 + 17, frame.height + 15, 4.0)] as [(CGFloat, CGFloat, CGFloat)] {
            let dot = NSView(frame: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor(white: 0.24, alpha: 1).cgColor
            dot.layer?.cornerRadius = d / 2
            addSubview(dot)
        }
        setAccessibilityRole(.button)
        setAccessibilityLabel(Strings.menuAttachSticker)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { run() }
}

/// The context menu's target highlight: a bubble-shaped layer over the row, white (incoming)
/// or a multiply tint (outgoing), faded in when the menu opens and out when it closes.
final class MenuHighlight: NSObject, NSMenuDelegate {
    /// The highlight (tests read where it is drawn).
    let layer: CALayer
    private weak var host: NSView?
    /// cmux (u9489): the row's layer the highlight lives in, so it follows the row (scroll, a sent
    /// message, a reflow) instead of staying where the row was when the menu opened; nil: the host's layer.
    private weak var anchor: CALayer?
    /// The layer `shape` and `soft` are given in: the transcript view's, where the hit was measured.
    private weak var space: CALayer?
    /// The cell layer the same soft mask masks: the highlight's mask image is drawn the same way up (`start`).
    private weak var softOwner: CALayer?
    /// MessagesLab 7924f00 (cx-3cb soft-copies): `soft`, my text balloon's soft mask in the host's coordinates
    /// (MessagesWindowView.softMask): the highlight has the balloon's soft edge, not the crisp shape over it.
    /// `scale`: the view's renderScale.
    /// `shape`: the bubble's shared outline (`BubblePath.balloon`) in the host's coordinates.
    init(host: NSView, shape: CGPath, outgoing: Bool,
         soft: SoftBalloon.Mask? = nil, scale: CGFloat = Fixture.renderScale, softOwner: CALayer? = nil,
         anchor: CALayer? = nil, space: CALayer? = nil) {
        self.host = host
        self.softOwner = softOwner
        self.anchor = space == nil ? nil : anchor
        self.space = space
        // MessagesLab ced183d: incoming 59 -> 98.
        let tint = outgoing ? NSColor(srgbRed: 159 / 255, green: 154 / 255, blue: 198 / 255, alpha: 1).cgColor : NSColor(white: 1, alpha: 0.2).cgColor
        if outgoing, let m = soft {
            let l = CALayer(), mask = CALayer()
            l.frame = m.frame
            l.backgroundColor = tint
            mask.contents = m.image
            mask.contentsCenter = m.center
            mask.contentsScale = scale
            mask.frame = l.bounds
            l.mask = mask
            layer = l
        } else {
            let l = CAShapeLayer()
            l.path = shape
            l.fillColor = tint
            layer = l
        }
        if outgoing { layer.compositingFilter = "multiplyBlendMode" }
        super.init()
        layer.opacity = 0
    }
    private var keys: Any?
    private var closing = false
    deinit { if let k = keys { NSEvent.removeMonitor(k) } }
    /// MessagesLab ced183d: the highlight starts with the press, when AppKit asks for the menu,
    /// and is committed at once, before AppKit's synchronous menu layout (30-75 ms per open), so
    /// the render server runs its fade during that work as Messages shows it.
    func start() {
        guard let root = anchor ?? host?.layer, layer.superlayer == nil else { return }
        if let anchor, let space { place(in: anchor, from: space) }
        root.addSublayer(layer)
        layer.zPosition = 10
        // MessagesLab 7924f00: the mask image upright as in the cell (its tail at the bottom right): a layer under an
        // odd number of flipped ancestors draws its contents the other way up than one under an even number.
        if let owner = softOwner, let mask = layer.mask, layer.contentsAreFlipped() != owner.contentsAreFlipped() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            mask.transform = CATransform3DMakeScale(1, -1, 1)
            CATransaction.commit()
        }
        fade(to: 1, at: CACurrentMediaTime(), duration: 0.2)
        CATransaction.flush()
    }
    /// Moves the highlight from `space`'s coordinates into `anchor`'s (the row's), once, before it is
    /// added: from then on the row's own position carries it.
    private func place(in anchor: CALayer, from space: CALayer) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let shape = layer as? CAShapeLayer, let path = shape.path {
            let box = path.boundingBoxOfPath
            let to = anchor.convert(box, from: space)
            var t = CGAffineTransform(translationX: to.minX - box.minX, y: to.minY - box.minY)
            shape.path = path.copy(using: &t)
        } else {
            layer.frame = anchor.convert(layer.frame, from: space)
        }
    }
    /// MessagesLab 7518134: media time of menuWillOpen (an input before it did not choose an item).
    private(set) var openedAt: CFTimeInterval?
    /// Removes the highlight at once, no fade (a menu built and never shown: the debug socket).
    func discard() {
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.removeFromSuperlayer(); CATransaction.commit()
    }
    func menuWillOpen(_ menu: NSMenu) {
        openedAt = CACurrentMediaTime()
        start()
        // Esc (MessagesLab e17858e): the highlight's fade starts and commits before AppKit tears
        // the menu down on main (the teardown held the commit 30-40 ms: a late, jumping fade);
        // cancelTracking() animates the menu's own dismissal, as Messages' Esc does.
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak menu] e in
            guard e.keyCode == 53, let menu else { return e }
            self?.close()
            menu.cancelTracking()
            return nil
        }
    }
    func menuDidClose(_ menu: NSMenu) {
        if let k = keys { NSEvent.removeMonitor(k); keys = nil }
        // MessagesLab 7518134: AppKit sends the chosen item's action after this; a tapback fades the
        // highlight with its badge (fadeForChoice), so the plain fade waits for the next main
        // run-loop pass (no timer; an action AppKit sends later finds the fade running, as before).
        RunLoop.main.perform(inModes: [.common]) { self.close() }
    }
    /// MessagesLab 7518134: Messages fades the highlight with the tapback, CA's default curve over
    /// 0.228 s, beginning 0.120 s after the tapback's origin (tapback-menu-heart-take1).
    static let choiceFade = (delay: CFTimeInterval(0.120), duration: CFTimeInterval(0.228), curve: CAMediaTimingFunctionName.default)
    /// A tapback chosen in the menu: the fade starts `choiceFade.delay` after `origin` (media time; nil: now).
    func fadeForChoice(origin: CFTimeInterval?) {
        let f = Self.choiceFade
        close(at: origin.map { max(CACurrentMediaTime(), $0 + f.delay) }, duration: f.duration, curve: f.curve)
    }
    /// Fades the highlight out once (Esc starts it before the menu's teardown; a click when the
    /// menu has closed, a tapback with its badge) and commits the fade at once.
    private func close(at begin: CFTimeInterval? = nil, duration: CFTimeInterval = 0.2,
                       curve: CAMediaTimingFunctionName = .easeInEaseOut) {
        guard !closing, layer.superlayer != nil else { return }
        closing = true
        let l = layer
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        fade(to: 0, at: begin ?? CACurrentMediaTime(), duration: duration, curve: curve)
        CATransaction.commit()
        CATransaction.flush()
    }
    private func fade(to v: Float, at begin: CFTimeInterval, duration: CFTimeInterval,
                      curve: CAMediaTimingFunctionName = .easeInEaseOut) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = layer.presentation()?.opacity ?? layer.opacity
        a.toValue = v
        a.beginTime = begin
        a.duration = duration
        a.fillMode = .backwards
        a.timingFunction = CAMediaTimingFunction(name: curve)
        layer.opacity = v
        layer.add(a, forKey: "hl")
    }
}
