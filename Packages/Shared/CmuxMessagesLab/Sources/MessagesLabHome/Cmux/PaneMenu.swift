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
        // incoming 59 -> 91, outgoing (72,147,247) -> (45,89,192), in about 0.22 s after
        // 0.08 s; back when the menu closes).
        let hl = MenuHighlight(host: host, body: hit.body, outgoing: hit.row.outgoing, tail: hit.row.tail)
        menu.delegate = hl
        menuHighlight = hl
        // cmux: tapbacks only while the owner takes them (`canReact`, false offline).
        let canReact = intents?.canReact == true
        if canReact {
            TapbackMenuRows.items(current: current, react: { [weak self] in self?.intents?.react(ref, $0) },
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
            menu.addItem(MenuAction(title: Strings.menuAttachSticker, symbol: NSImage(systemSymbolName: "sticker", accessibilityDescription: nil) != nil ? "sticker" : "face.smiling") { [weak self] in self?.showPicker(for: hit) })
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
        let f = cell.convert(cell.bounds, to: demo)
        let scale = window.backingScaleFactor
        guard let ctx = CGContext(data: nil, width: Int(f.width * scale), height: Int(f.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: DisplayScale.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
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
        let glass = NSGlassEffectView(frame: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
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
    private let layer = CAShapeLayer()
    private weak var host: NSView?
    init(host: NSView, body: CGRect, outgoing: Bool, tail: Bool) {
        self.host = host
        super.init()
        layer.path = BubblePath.make(body: body, outgoing: outgoing, tail: tail).cgPath
        if outgoing {
            layer.fillColor = NSColor(srgbRed: 159 / 255, green: 154 / 255, blue: 198 / 255, alpha: 1).cgColor
            layer.compositingFilter = "multiplyBlendMode"
        } else {
            layer.fillColor = NSColor(white: 1, alpha: 0.163).cgColor
        }
        layer.opacity = 0
    }
    func menuWillOpen(_ menu: NSMenu) {
        guard let root = host?.layer else { return }
        root.addSublayer(layer)
        layer.zPosition = 10
        fade(to: 1, delay: 0.08, duration: 0.22)
    }
    func menuDidClose(_ menu: NSMenu) {
        let l = layer
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        fade(to: 0, delay: 0, duration: 0.2)
        CATransaction.commit()
    }
    private func fade(to v: Float, delay: CFTimeInterval, duration: CFTimeInterval) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = layer.presentation()?.opacity ?? layer.opacity
        a.toValue = v
        a.beginTime = CACurrentMediaTime() + delay
        a.duration = duration
        a.fillMode = .backwards
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = v
        layer.add(a, forKey: "hl")
    }
}
