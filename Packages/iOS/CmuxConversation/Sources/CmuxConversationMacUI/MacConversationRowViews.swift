#if os(macOS)
import AppKit
import CmuxConversationCore
import CmuxConversationGeometry

/// A flipped, layer-backed view so layouts share UIKit's top-left origin.
class MacFlippedView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A non-editing label that draws attributed text.
@MainActor
func makeMacLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.isSelectable = false
    label.drawsBackground = false
    label.isBordered = false
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.cell?.wraps = true
    return label
}

/// Draws attributed text with the same metrics `boundingRect` measured, so
/// bubbles size exactly (an NSTextField would add its own padding).
final class MacMeasuredTextView: MacFlippedView {
    var attributedText = NSAttributedString() { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        attributedText.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class MacBubbleLayer: CAShapeLayer {
    func update(rect: CGRect, side: ConversationBubbleGeometry.Side, tail: Bool) {
        let t = MacConversationTheme.self
        path = ConversationBubbleGeometry.path(
            in: rect, side: side, tail: tail,
            radius: t.bubbleCornerRadius, tailWidth: t.tailWidth, tailDrop: t.tailDrop, style: .macOS
        )
    }
}

final class MacAvatarView: MacFlippedView {
    private let gradient = CAGradientLayer()
    private let label = makeMacLabel()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(gradient)
        gradient.colors = [
            NSColor(srgbRed: 0.66, green: 0.69, blue: 0.74, alpha: 1).cgColor,
            NSColor(srgbRed: 0.53, green: 0.56, blue: 0.62, alpha: 1).cgColor,
        ]
        label.alignment = .center
        label.textColor = .white
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        label.cell?.wraps = false
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var initials = "" { didSet { label.stringValue = initials } }

    /// Tints the monogram with a participant color (Messages derives one per contact).
    var colorHex: String? {
        didSet {
            guard let colorHex, let base = NSColor(hexString: colorHex) else {
                gradient.colors = [
                    NSColor(srgbRed: 0.66, green: 0.69, blue: 0.74, alpha: 1).cgColor,
                    NSColor(srgbRed: 0.53, green: 0.56, blue: 0.62, alpha: 1).cgColor,
                ]
                return
            }
            // Messages monograms are muted contact tints, not saturated colors.
            let muted = base.blended(withFraction: 0.6, of: NSColor(srgbRed: 0.45, green: 0.47, blue: 0.5, alpha: 1))!
            gradient.colors = [muted.blended(withFraction: 0.15, of: .white)!.cgColor, muted.blended(withFraction: 0.2, of: .black)!.cgColor]
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        layer?.masksToBounds = true
        gradient.frame = bounds
        label.font = .systemFont(ofSize: bounds.width * 0.4, weight: .semibold)
        let h = label.font!.boundingRectForFont.height
        label.frame = CGRect(x: -4, y: (bounds.height - h) / 2 + 1, width: bounds.width + 8, height: h)
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        var value: UInt64 = 0
        guard Scanner(string: hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

enum MacTapbackGlyph {
    static func text(_ reaction: ConversationReaction) -> NSAttributedString {
        switch reaction {
        case .heart: return emoji("\u{1FA77}")
        case .thumbsup: return emoji("\u{1F44D}")
        case .thumbsdown: return emoji("\u{1F44E}")
        case .exclamation: return emoji("\u{203C}\u{FE0F}")
        case .haha:
            return NSAttributedString(string: "HA\nHA", attributes: [
                .font: NSFont.systemFont(ofSize: 7, weight: .black),
                .foregroundColor: NSColor(srgbRed: 0.18, green: 0.62, blue: 1, alpha: 1),
                .paragraphStyle: centered(lineHeight: 7),
            ])
        case .question:
            return NSAttributedString(string: "?", attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .black),
                .foregroundColor: NSColor(srgbRed: 0.62, green: 0.45, blue: 1, alpha: 1),
                .paragraphStyle: centered(lineHeight: 0),
            ])
        }
    }

    private static func emoji(_ value: String) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: centered(lineHeight: 0)])
    }

    private static func centered(lineHeight: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        if lineHeight > 0 {
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
        }
        return style
    }
}

/// One message row: sender name, reply quote, images, bubble or large emoji,
/// tapback badge, avatar and footers, placed from a `MacMessageLayout`.
final class MacMessageRowView: MacFlippedView {
    let bubble = MacBubbleLayer()
    let textLabel = MacMeasuredTextView()
    let emojiLabel = makeMacLabel()
    let senderLabel = makeMacLabel()
    let quoteBubble = MacBubbleLayer()
    let quoteLabel = makeMacLabel()
    let threadLine = CAShapeLayer()
    let avatar = MacAvatarView()
    let quoteAvatar = MacAvatarView()
    let badge = MacFlippedView()
    private var badgeCircles: [MacFlippedView] = []
    let editedLabel = makeMacLabel()
    let repliesLabel = makeMacLabel()
    let footerLabel = makeMacLabel()
    let failedBadge = NSImageView()
    private var imageViews: [NSImageView] = []
    private var imageTasks: [Task<Void, Never>] = []
    private(set) var model: MacMessageRowModel?
    private(set) var rowLayout: MacMessageLayout?
    private var lastFooterRowID: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(threadLine)
        threadLine.fillColor = nil
        threadLine.lineWidth = 2
        threadLine.lineCap = .round
        layer?.addSublayer(quoteBubble)
        quoteBubble.lineWidth = 1
        layer?.addSublayer(bubble)
        addSubview(textLabel)
        for label in [emojiLabel, senderLabel, quoteLabel, editedLabel, repliesLabel, footerLabel] {
            addSubview(label)
        }
        senderLabel.font = MacConversationTheme.senderNameFont
        senderLabel.textColor = MacConversationTheme.secondaryText
        quoteLabel.font = .systemFont(ofSize: 10)
        quoteLabel.maximumNumberOfLines = 2
        quoteLabel.lineBreakMode = .byTruncatingTail
        editedLabel.font = MacConversationTheme.editedFont
        editedLabel.textColor = .systemBlue
        repliesLabel.font = MacConversationTheme.editedFont
        repliesLabel.textColor = .systemBlue
        footerLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        emojiLabel.font = .systemFont(ofSize: MacConversationTheme.emojiOnlyFontSize)
        addSubview(avatar)
        addSubview(quoteAvatar)
        addSubview(badge)
        failedBadge.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
        failedBadge.contentTintColor = .systemRed
        failedBadge.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        addSubview(failedBadge)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ model: MacMessageRowModel, layout: MacMessageLayout, text: NSAttributedString) {
        let sameRow = self.model?.rowID == model.rowID
        let hadFooter = self.model?.footer ?? .none
        self.model = model
        rowLayout = layout
        let side: ConversationBubbleGeometry.Side = model.isOutgoing ? .trailing : .leading

        if let frame = layout.bubbleFrame, let textFrame = layout.textFrame {
            bubble.isHidden = false
            bubble.update(rect: frame, side: side, tail: model.showsTail)
            bubble.fillColor = resolved(model.isOutgoing ? MacConversationTheme.outgoingBubble : MacConversationTheme.incomingBubble, in: self)
            bubble.opacity = model.footer == .notDelivered ? 0.85 : 1
            textLabel.isHidden = false
            textLabel.attributedText = text
            textLabel.frame = textFrame
        } else {
            bubble.isHidden = true
            textLabel.isHidden = true
        }

        emojiLabel.isHidden = layout.emojiFrame == nil
        if let frame = layout.emojiFrame {
            emojiLabel.stringValue = model.message.text
            emojiLabel.frame = frame
        }

        senderLabel.isHidden = layout.senderNameFrame == nil
        if let frame = layout.senderNameFrame {
            senderLabel.stringValue = model.senderName ?? ""
            senderLabel.frame = frame
        }

        if let quote = model.replyQuote, let frame = layout.quoteFrame, let textFrame = layout.quoteTextFrame {
            quoteBubble.isHidden = false
            quoteBubble.update(rect: frame, side: quote.isOutgoing ? .trailing : .leading, tail: true)
            quoteBubble.fillColor = nil
            quoteBubble.strokeColor = resolved(quote.isOutgoing ? MacConversationTheme.outgoingBubble : MacConversationTheme.quoteStroke, in: self)
            quoteLabel.isHidden = false
            var attributes = MacConversationTheme.quoteAttributes
            (attributes[.paragraphStyle] as? NSParagraphStyle).map { style in
                let truncating = style.mutableCopy() as! NSMutableParagraphStyle
                truncating.lineBreakMode = .byTruncatingTail
                attributes[.paragraphStyle] = truncating
            }
            attributes[.foregroundColor] = quote.isOutgoing ? NSColor.systemBlue : MacConversationTheme.secondaryText
            quoteLabel.attributedStringValue = NSAttributedString(string: quote.text, attributes: attributes)
            quoteLabel.textColor = quote.isOutgoing ? .systemBlue : MacConversationTheme.secondaryText
            // NSTextField insets its text ~2 pt per side; without this a short
            // quote (one emoji) measures exactly and truncates to nothing.
            quoteLabel.frame = textFrame.insetBy(dx: -3, dy: 0)
        } else {
            quoteBubble.isHidden = true
            quoteLabel.isHidden = true
        }
        quoteAvatar.isHidden = layout.quoteAvatarFrame == nil
        if let frame = layout.quoteAvatarFrame, let quote = model.replyQuote {
            quoteAvatar.frame = frame
            quoteAvatar.initials = quote.senderInitials
            quoteAvatar.colorHex = quote.senderColorHex
        }
        threadLine.path = layout.threadPath
        threadLine.isHidden = layout.threadPath == nil
        threadLine.strokeColor = resolved(MacConversationTheme.threadLine, in: self)

        avatar.isHidden = layout.avatarFrame == nil
        if let frame = layout.avatarFrame {
            avatar.frame = frame
            avatar.initials = model.senderInitials
            avatar.colorHex = model.senderColorHex
        }

        configureBadge(model, layout: layout)
        configureImages(model, layout: layout)

        editedLabel.isHidden = layout.editedFrame == nil
        if let frame = layout.editedFrame {
            editedLabel.stringValue = String(localized: "conversation.message.edited", defaultValue: "Edited", bundle: .module)
            editedLabel.alignment = model.isOutgoing ? .right : .left
            editedLabel.frame = frame
        }
        repliesLabel.isHidden = layout.repliesFrame == nil
        if let frame = layout.repliesFrame {
            repliesLabel.stringValue = model.message.replyCount == 1
                ? String(localized: "conversation.message.oneReply", defaultValue: "1 Reply", bundle: .module)
                : String(format: String(localized: "conversation.message.replies", defaultValue: "%d Replies", bundle: .module), model.message.replyCount)
            repliesLabel.alignment = model.isOutgoing ? .right : .left
            repliesLabel.frame = frame
        }

        switch model.footer {
        case .none:
            footerLabel.isHidden = true
        case let .status(text):
            footerLabel.isHidden = false
            footerLabel.stringValue = text
            footerLabel.textColor = MacConversationTheme.secondaryText
        case .notDelivered:
            footerLabel.isHidden = false
            footerLabel.stringValue = String(localized: "conversation.status.notDelivered", defaultValue: "Not Delivered", bundle: .module)
            footerLabel.textColor = .systemRed
        }
        if let frame = layout.footerFrame {
            footerLabel.alignment = model.isOutgoing ? .right : .left
            footerLabel.frame = frame
        }
        // A status landing on this row fades in.
        if sameRow, hadFooter == .none, model.footer != .none {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.4
            footerLabel.layer?.add(fade, forKey: "statusFade")
        }
        failedBadge.isHidden = layout.failedBadgeFrame == nil
        if let frame = layout.failedBadgeFrame { failedBadge.frame = frame }

        toolTip = model.message.sentAt.formatted(date: .abbreviated, time: .shortened)
        setAccessibilityLabel([model.isOutgoing ? nil : model.senderName, model.message.text].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityIdentifier("conversation.message.\(model.message.id)")
    }

    /// Every distinct tapback gets its own circle; circles overlap by 45%,
    /// newest in front, mine tinted blue.
    private func configureBadge(_ model: MacMessageRowModel, layout: MacMessageLayout) {
        guard let anchor = layout.reactionAnchor else {
            badge.isHidden = true
            return
        }
        badge.isHidden = false
        let s = MacConversationTheme.reactionBadgeSize
        let kinds = Array(model.reactionKinds.prefix(3))
        let step = s * 0.55
        let width = s + CGFloat(max(0, kinds.count - 1)) * step
        let x = model.isOutgoing ? anchor.x - width + 9 : anchor.x - 9
        badge.frame = CGRect(x: x, y: anchor.y - s + 10, width: width, height: s)
        badge.layer?.backgroundColor = nil
        while badgeCircles.count < kinds.count {
            let circle = MacFlippedView()
            let label = makeMacLabel()
            label.maximumNumberOfLines = 2
            circle.addSubview(label)
            badge.addSubview(circle)
            badgeCircles.append(circle)
        }
        let mine = model.myReactions
        for (index, circle) in badgeCircles.enumerated() {
            guard index < kinds.count else {
                circle.isHidden = true
                continue
            }
            circle.isHidden = false
            // Leading circles sit behind; on outgoing rows the stack grows leftward.
            let order = model.isOutgoing ? kinds.count - 1 - index : index
            circle.frame = CGRect(x: CGFloat(order) * step, y: 0, width: s, height: s)
            circle.layer?.cornerRadius = s / 2
            circle.layer?.borderWidth = 1.5
            circle.layer?.borderColor = resolved(MacConversationTheme.background, in: self)
            circle.layer?.backgroundColor = resolved(mine.contains(kinds[index]) ? NSColor.systemBlue : MacConversationTheme.badgeFill, in: self)
            circle.layer?.zPosition = CGFloat(index)
            guard let label = circle.subviews.first as? NSTextField else { continue }
            let text = MacTapbackGlyph.text(kinds[index])
            label.attributedStringValue = text
            let h = text.boundingRect(with: CGSize(width: s, height: s), options: [.usesLineFragmentOrigin]).height
            label.frame = CGRect(x: 0, y: (s - ceil(h)) / 2, width: s, height: ceil(h) + 1)
        }
    }

    private func configureImages(_ model: MacMessageRowModel, layout: MacMessageLayout) {
        imageTasks.forEach { $0.cancel() }
        imageTasks = []
        while imageViews.count < layout.imageFrames.count {
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            addSubview(view, positioned: .below, relativeTo: badge)
            imageViews.append(view)
        }
        for (index, view) in imageViews.enumerated() {
            guard index < layout.imageFrames.count, index < model.message.attachments.count else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            let frame = layout.imageFrames[index]
            view.frame = frame
            let tailed = model.showsTail && index == layout.imageFrames.count - 1 && model.message.text.isEmpty
            let mask = CAShapeLayer()
            mask.path = ConversationBubbleGeometry.path(
                in: CGRect(origin: .zero, size: frame.size), side: model.isOutgoing ? .trailing : .leading, tail: tailed,
                radius: MacConversationTheme.bubbleCornerRadius, tailWidth: MacConversationTheme.tailWidth, tailDrop: 0, style: .macOS
            )
            view.layer?.mask = mask
            let attachment = model.message.attachments[index]
            if let cached = MacImageLoader.shared.cached(attachment) {
                view.image = cached
                continue
            }
            let rowID = model.rowID
            imageTasks.append(Task { @MainActor [weak self, weak view] in
                let image = await MacImageLoader.shared.image(for: attachment)
                guard let self, let view, self.model?.rowID == rowID else { return }
                view.image = image
            })
        }
    }

    /// The bubble/content area, for hit testing and menus.
    var contentFrame: CGRect { rowLayout?.contentFrame ?? bounds }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Resolved CGColors (bubble fills, strokes, badges) follow the new appearance now.
        guard let model, let rowLayout else { return }
        configure(model, layout: rowLayout, text: textLabel.attributedText)
        textLabel.needsDisplay = true
    }

    private func spring(_ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.mass = 1
        animation.stiffness = 240
        animation.damping = 26
        animation.duration = animation.settlingDuration
        return animation
    }

    /// The send flight: the bubble starts at the composer field's frame and
    /// width and springs to its slot; the text glides from the field's text.
    func flyIn(fromField field: CGRect, text: CGRect) {
        guard let rowLayout else { return }
        let identity = NSValue(caTransform3D: CATransform3DIdentity)
        if let frame = rowLayout.bubbleFrame, frame.width > 0, frame.height > 0 {
            var start = CATransform3DMakeTranslation(-frame.minX, -frame.minY, 0)
            start = CATransform3DConcat(start, CATransform3DMakeScale(field.width / frame.width, field.height / frame.height, 1))
            start = CATransform3DConcat(start, CATransform3DMakeTranslation(field.minX, field.minY, 0))
            bubble.add(spring("transform", from: NSValue(caTransform3D: start), to: identity), forKey: "flight")
        }
        if let target = rowLayout.textFrame {
            let dx = text.minX - target.minX
            let dy = text.minY + (min(text.height, field.height) - target.height) / 2 - target.minY
            textLabel.layer?.add(spring("transform", from: NSValue(caTransform3D: CATransform3DMakeTranslation(dx, dy, 0)), to: identity), forKey: "flight")
        }
        let content = rowLayout.emojiFrame ?? rowLayout.imageFrames.first
        if let content {
            let shift = NSValue(caTransform3D: CATransform3DMakeTranslation(field.minX - content.minX, field.minY - content.minY, 0))
            for view in [emojiLabel] + imageViews where !view.isHidden {
                view.layer?.add(spring("transform", from: shift, to: identity), forKey: "flight")
            }
        }
    }

    /// Arrivals: the bubble grows from its tail corner (bottom leading edge)
    /// and fades in; the avatar and sender name do not scale.
    func growIn() {
        guard let rowLayout else { return }
        let content = rowLayout.contentFrame
        let pivot = CGPoint(x: model?.isOutgoing == true ? content.maxX : content.minX, y: content.maxY)
        func scaled(_ s: CGFloat, origin: CGPoint) -> NSValue {
            let p = CGPoint(x: pivot.x - origin.x, y: pivot.y - origin.y)
            var m = CATransform3DMakeTranslation(-p.x, -p.y, 0)
            m = CATransform3DConcat(m, CATransform3DMakeScale(s, s, 1))
            m = CATransform3DConcat(m, CATransform3DMakeTranslation(p.x, p.y, 0))
            return NSValue(caTransform3D: m)
        }
        var targets: [(CALayer, CGPoint)] = [(bubble, .zero)]
        for view in [textLabel, emojiLabel, badge] + imageViews where !view.isHidden {
            if let layer = view.layer { targets.append((layer, view.frame.origin)) }
        }
        for (layer, origin) in targets {
            layer.add(spring("transform", from: scaled(0.6, origin: origin), to: NSValue(caTransform3D: CATransform3DIdentity)), forKey: "arrive")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.15
            layer.add(fade, forKey: "arriveFade")
        }
    }
}

@MainActor
final class MacImageLoader {
    static let shared = MacImageLoader()
    private let cache = NSCache<NSString, NSImage>()

    func cached(_ attachment: ConversationAttachment) -> NSImage? {
        cache.object(forKey: attachment.id as NSString)
    }

    func image(for attachment: ConversationAttachment) async -> NSImage? {
        if let cached = cached(attachment) { return cached }
        let data: Data?
        if let local = attachment.localData {
            data = local
        } else if let url = attachment.url {
            data = try? await URLSession.shared.data(from: url).0
        } else {
            data = nil
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: attachment.id as NSString)
        return image
    }
}

final class MacTimestampRowView: MacFlippedView {
    let label = makeMacLabel()
    static let height: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(date: Date) {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = String(localized: "conversation.timestamp.today", defaultValue: "Today", bundle: .module)
        } else if calendar.isDateInYesterday(date) {
            day = String(localized: "conversation.timestamp.yesterday", defaultValue: "Yesterday", bundle: .module)
        } else {
            day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let text = NSMutableAttributedString(string: day, attributes: [
            .font: MacConversationTheme.timestampBoldFont, .foregroundColor: MacConversationTheme.secondaryText, .paragraphStyle: centered,
        ])
        text.append(NSAttributedString(string: " " + date.formatted(date: .omitted, time: .shortened), attributes: [
            .font: MacConversationTheme.timestampFont, .foregroundColor: MacConversationTheme.secondaryText, .paragraphStyle: centered,
        ]))
        label.attributedStringValue = text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 0, y: 8, width: bounds.width, height: 14)
    }
}

final class MacSpinnerRowView: MacFlippedView {
    let spinner = NSProgressIndicator()
    /// Tall enough that the spinner clears the toolbar's soft scroll edge
    /// when the reader reaches the top while a page loads.
    static let height: CGFloat = 56

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        setAccessibilityIdentifier("conversation.loadingOlder")
        setAccessibilityLabel(String(localized: "conversation.loadingOlder", defaultValue: "Loading earlier messages", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        spinner.frame = CGRect(x: bounds.midX - 8, y: bounds.height - 16 - 12, width: 16, height: 16)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? spinner.stopAnimation(nil) : spinner.startAnimation(nil)
    }
}

final class MacConversationStartRowView: MacFlippedView {
    let label = makeMacLabel()
    static let height: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .center
        label.font = MacConversationTheme.timestampFont
        label.textColor = MacConversationTheme.secondaryText
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, subtitle: String) {
        label.stringValue = "\(title)\n\(subtitle)"
    }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 0, y: 8, width: bounds.width, height: 30)
    }
}

/// Three pulsing dots in an incoming bubble.
final class MacTypingRowView: MacFlippedView {
    private let bubble = MacBubbleLayer()
    private var dots: [CALayer] = []
    let avatar = MacAvatarView()
    var showsAvatar = false { didSet { needsLayout = true } }
    /// 0...1: the indicator grows from its tail corner as its row opens.
    var progress: CGFloat = 1 { didSet { applyProgress() } }
    static let height: CGFloat = 36

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(bubble)
        for _ in 0..<3 {
            let dot = CALayer()
            dot.cornerRadius = 3.5
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        addSubview(avatar)
        setAccessibilityIdentifier("conversation.typing")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let t = MacConversationTheme.self
        let leading = t.sideMargin + (showsAvatar ? t.avatarSize + t.avatarGap : 0)
        let frame = CGRect(x: leading - t.tailWidth, y: 2, width: 46 + t.tailWidth, height: 29)
        bubble.update(rect: frame, side: .leading, tail: true)
        bubble.fillColor = resolved(t.incomingBubble, in: self)
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: leading + 10 + CGFloat(index) * 11, y: frame.midY - 3.5, width: 7, height: 7)
            dot.backgroundColor = NSColor.secondaryLabelColor.cgColor
        }
        avatar.isHidden = !showsAvatar
        avatar.frame = CGRect(x: t.sideMargin, y: frame.maxY - t.avatarSize, width: t.avatarSize, height: t.avatarSize)
        bubbleFrame = frame
        applyProgress()
        startPulse()
    }

    private var bubbleFrame: CGRect = .zero

    private func applyProgress() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let p = CGPoint(x: bubbleFrame.minX, y: bubbleFrame.maxY)
        let scale = 0.5 + 0.5 * progress
        var m = CATransform3DMakeTranslation(-p.x, -p.y, 0)
        m = CATransform3DConcat(m, CATransform3DMakeScale(scale, scale, 1))
        m = CATransform3DConcat(m, CATransform3DMakeTranslation(p.x, p.y, 0))
        for layer in [bubble as CALayer] + dots {
            layer.transform = m
            layer.opacity = Float(progress)
        }
        avatar.alphaValue = progress
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func startPulse() {
        for (index, dot) in dots.enumerated() where dot.animation(forKey: "pulse") == nil {
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.35, 1, 0.35, 0.35]
            pulse.keyTimes = [0, 0.22, 0.44, 1]
            pulse.duration = 1.3
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.18
            dot.add(pulse, forKey: "pulse")
        }
    }
}
#endif
