import AppKit

/// MessagesLab 69f4256's context menu and picker chrome (Host.swift, not
/// vendored), for the pane controller: the real menu order (Tapback
/// Details…, Reply…, Attach Sticker…; Copy; Share…; Delete…), the target
/// bubble's highlight while the menu is open, the pressed bubble lifted
/// above the picker's dim, and the picker's emoji bubble. The differences
/// from Host.swift are marked `cmux:`.
extension ChatController {
    // MARK: Context menu

    func menu(at p: CGPoint) -> NSMenu? {
        guard let hit = demo?.hit(p) else { return nil }
        let ref = hit.row.ref
        let current = hit.row.reactions.first { $0.senderId == store?.state.me }?.kind
        let menu = NSMenu()
        // The pressed bubble is highlighted while the menu is open (real Messages, macOS 27:
        // incoming 59 -> 98, outgoing (72,147,247) -> (45,89,192), in about 0.2 s from
        // the press; back when the menu closes).
        // The drawn balloon with its frame's corners (MessagesLab 2281879 RowDraw.balloon).
        // MessagesLab 267d218: a 1-line text ends in half circles; 7924f00: my text balloon's soft edge (soft-copies).
        let hl = MenuHighlight(host: host, body: hit.outline, cornersOf: hit.body.size, outgoing: hit.row.outgoing, tail: hit.row.tail,
                               circularEnds: RowDraw.circularEnds(hit.row), soft: demo?.softMask(hit),
                               scale: demo?.renderScale ?? Fixture.renderScale, softOwner: demo?.softMaskOwner(hit))
        menu.delegate = hl
        menuHighlight = hl
        hl.start()
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
            menu.addItem(MenuAction(title: Strings.menuReplyEllipsis, symbol: "arrowshape.turn.up.left") { [weak self] in self?.dispatch(.reply(ref)); self?.focusCompose() })
        }
        // Attach Sticker…: opens the tapback picker with its emoji (no image stickers).
        if canReact {
            menu.addItem(MenuAction(title: Strings.menuAttachSticker, symbol: MenuSymbols.attachSticker) { [weak self] in self?.showPicker(for: hit) })
        }
        menu.addItem(.separator())
        // cmux: no Edit or Undo Send (HomeOp has no edit or unsend).
        if case let .text(text, _) = hit.row.part {
            menu.addItem(MenuAction(title: Strings.menuCopy) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) })
            menu.addItem(.separator())
        }
        // cmux: a video plays in place; opening it in an app is only here.
        if case let .attachment(a) = hit.row.part {
            if a.kind == "video", let intents {
                let playing = intents.videoState(ref) == .playing
                menu.addItem(MenuAction(title: playing ? CmuxStrings.pauseVideo : CmuxStrings.playVideo,
                                        symbol: playing ? "pause.fill" : "play.fill") { [weak self] in self?.intents?.toggleVideo(ref, a.id) })
            }
            menu.addItem(MenuAction(title: CmuxStrings.openInDefaultApp, symbol: "arrow.up.forward.app") { [weak self] in
                self?.intents?.openAttachment(ref.messageId, a.id)
            })
            menu.addItem(.separator())
        }
        // cmux: lane 16's Cancel Upload, only while the send can be cancelled.
        if intents?.canCancelSend(ref.messageId) == true {
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

    /// The pressed bubble stays bright above the dim (real Messages lifts it).
    func pickerLift(for hit: MessagesWindowView.Hit) -> NSView? {
        guard let demo, let window,
              let cell = demo.collection.visibleCells.compactMap({ $0 as? RowCell }).first(where: { $0.spec?.key == hit.key }) else { return nil }
        // The row's content rests on the window's device pixels (RowCell.snapRow, MessagesLab c1457e5): the bitmap
        // starts at the content's place, so the lifted bubble keeps whole pixels and is not resampled.
        let d = cell.rowSnap
        let f = cell.convert(cell.bounds, to: demo).offsetBy(dx: d.x, dy: d.y)
        let scale = window.backingScaleFactor
        guard let ctx = CGContext(data: nil, width: CrashGuard.int(f.width * scale, in: 1...16_384), height: CrashGuard.int(f.height * scale, in: 1...16_384), /* crash program: no trap on NaN */ bitsPerComponent: 8, bytesPerRow: 0,
                                  space: DisplayScale.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -d.x, y: -d.y)
        cell.layer.render(in: ctx)
        let lift = NSView(frame: f)
        lift.wantsLayer = true
        lift.layer?.contents = ctx.makeImage()
        lift.layer?.contentsScale = scale
        lift.layer?.isGeometryFlipped = true
        return lift
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
    private let layer: CALayer
    private weak var host: NSView?
    /// The cell layer the same soft mask masks: the highlight's mask image is drawn the same way up (`start`).
    private weak var softOwner: CALayer?
    /// MessagesLab 7924f00 (cx-3cb soft-copies): `soft`, my text balloon's soft mask in the host's coordinates
    /// (MessagesWindowView.softMask): the highlight has the balloon's soft edge, not the crisp shape over it.
    /// `scale`: the view's renderScale.
    init(host: NSView, body: CGRect, cornersOf frame: CGSize? = nil, outgoing: Bool, tail: Bool, circularEnds: Bool = false,
         soft: SoftBalloon.Mask? = nil, scale: CGFloat = Fixture.renderScale, softOwner: CALayer? = nil) {
        self.host = host
        self.softOwner = softOwner
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
            l.path = BubblePath.make(body: body, outgoing: outgoing, tail: tail, cornersOf: frame, circularEnds: circularEnds).cgPath
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
        guard let root = host?.layer, layer.superlayer == nil else { return }
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
