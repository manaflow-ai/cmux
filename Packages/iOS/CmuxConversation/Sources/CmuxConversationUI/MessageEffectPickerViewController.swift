#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Messages "Send with effect": a long press on the send button opens a
/// blurred sheet with a Bubble/Screen switch. Bubble lists Slam, Loud,
/// Gentle and Invisible Ink; picking one moves the draft bubble above it and
/// plays the effect, and its dot becomes the send button. Screen pages
/// through the eight full-screen effects with a looping live preview.
final class MessageEffectPickerViewController: UIViewController, UIScrollViewDelegate {
    enum Mode: Int {
        case bubble
        case screen
    }

    var onSend: ((ConversationMessageEffect) -> Void)?
    var onCancel: (() -> Void)?

    private let text: NSAttributedString
    /// The composer's send button, in window coordinates: the cancel button
    /// takes its place so the finger that long-pressed lands on it.
    private let sendButtonFrame: CGRect
    private let reduceMotion: Bool
    /// What the backdrop blurs: the conversation, in another window.
    private weak var backdropSource: UIView?

    /// Messages' backdrop (`EffectPickerBackdrop`): the conversation behind,
    /// tinted and blurred at radius 64, under a black (light: white) wash.
    private let backdrop = UIImageView()
    private let backdropWash = UIView()
    private let titleLabel = UILabel()
    private let modeControl = UISegmentedControl(items: [ConversationEffectStrings.bubble, ConversationEffectStrings.screen])
    private let cancelButton = UIButton(type: .custom)
    /// The white capsule behind the bubble effects' dots (plus-lighter gray).
    private let track = UIView()
    private let stage = MessageBubbleStage()
    private var rows: [EffectRow] = []
    private let screenPreview = ScreenEffectView()
    private let pager = UIScrollView()
    private var pageLabels: [UILabel] = []
    private let pageControl = UIPageControl()
    private let screenSendButton = EffectSendButton()

    private(set) var mode: Mode = .bubble
    private(set) var selectedBubbleEffect: ConversationMessageEffect?
    private(set) var screenPage = 0
    private var previewGeneration = 0

    static let previewLineLimit = 3

    init(text: NSAttributedString, sendButtonFrame: CGRect, reduceMotion: Bool, backdropSource: UIView) {
        self.text = text
        self.sendButtonFrame = sendButtonFrame
        self.reduceMotion = reduceMotion
        self.backdropSource = backdropSource
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
        backdrop.contentMode = .scaleToFill
        view.addSubview(backdrop)
        backdropWash.backgroundColor = UIColor {
            let backdrop = EffectPickerBackdrop(dark: $0.userInterfaceStyle == .dark)
            return UIColor(white: backdrop.washWhite, alpha: backdrop.washAlpha)
        }
        backdropWash.isUserInteractionEnabled = false
        view.addSubview(backdropWash)

        screenPreview.alpha = 0
        view.addSubview(screenPreview)

        titleLabel.text = ConversationEffectStrings.sendWithEffect
        // Messages: 22 pt regular in gray 90 (CKEffectPickerStandardView).
        titleLabel.font = .systemFont(ofSize: 22)
        titleLabel.textColor = Self.secondaryInk
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header
        view.addSubview(titleLabel)

        modeControl.selectedSegmentIndex = 0
        modeControl.accessibilityIdentifier = "conversation.effects.mode"
        modeControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setMode(Mode(rawValue: self.modeControl.selectedSegmentIndex) ?? .bubble)
        }, for: .valueChanged)
        view.addSubview(modeControl)

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.delegate = self
        pager.isHidden = true
        pager.accessibilityIdentifier = "conversation.effects.pager"
        view.addSubview(pager)
        for effect in ConversationMessageEffect.screenEffects {
            let label = UILabel()
            label.text = effect.localizedName
            label.font = .systemFont(ofSize: 17, weight: .semibold)
            label.textColor = .label
            label.textAlignment = .center
            pager.addSubview(label)
            pageLabels.append(label)
        }
        pageControl.numberOfPages = ConversationMessageEffect.screenEffects.count
        pageControl.currentPageIndicatorTintColor = .label
        pageControl.pageIndicatorTintColor = .tertiaryLabel
        pageControl.isHidden = true
        pageControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.scrollToPage(self.pageControl.currentPage, animated: true)
        }, for: .valueChanged)
        view.addSubview(pageControl)

        let outgoing = MessageCellLayout.attributedBody(text.string, outgoing: true)
        stage.configure(side: .trailing, tail: true, fill: ConversationTheme.outgoingBubble, text: outgoing, bubbleFrame: .zero, textFrame: .zero)
        stage.label.numberOfLines = Self.previewLineLimit
        stage.label.lineBreakMode = .byTruncatingTail
        view.addSubview(stage)

        // Plus-lighter gray 72 (40 in dark mode): white over the light blur.
        track.backgroundColor = UIColor { UIColor(white: ($0.userInterfaceStyle == .dark ? 40 : 72) / 255, alpha: 1) }
        track.layer.compositingFilter = "plusL"
        track.layer.cornerRadius = EffectPickerGeometry.trackCornerRadius
        track.layer.cornerCurve = .continuous
        track.isUserInteractionEnabled = false
        view.addSubview(track)

        for effect in ConversationMessageEffect.bubbleEffects {
            let row = EffectRow(effect: effect)
            row.dot.addAction(UIAction { [weak self] _ in self?.dotTapped(effect) }, for: .touchUpInside)
            row.labelButton.addAction(UIAction { [weak self] _ in self?.select(effect) }, for: .touchUpInside)
            view.addSubview(row.labelButton)
            view.addSubview(row.dot)
            rows.append(row)
        }

        screenSendButton.isSelectedForSend = true
        screenSendButton.isHidden = true
        screenSendButton.accessibilityIdentifier = "conversation.effects.screenSend"
        screenSendButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.send(ConversationMessageEffect.screenEffects[self.screenPage])
        }, for: .touchUpInside)
        view.addSubview(screenSendButton)

        // Messages' CKPillShapedXButton: a gray pill in the send button's
        // place with a white 18 pt cross.
        var cancel = UIButton.Configuration.filled()
        cancel.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        cancel.baseBackgroundColor = UIColor(white: 0.5, alpha: 1)
        cancel.baseForegroundColor = .white
        cancel.cornerStyle = .capsule
        cancel.contentInsets = .zero
        cancelButton.configuration = cancel
        cancelButton.accessibilityLabel = ConversationEffectStrings.cancel
        cancelButton.accessibilityIdentifier = "conversation.effects.cancel"
        cancelButton.addAction(UIAction { [weak self] _ in self?.cancel() }, for: .touchUpInside)
        view.addSubview(cancelButton)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Over a focused field the picker leaves first responder alone, so
        // the keyboard stays (ConversationKeyboardFocusPolicy).
        if ConversationKeyboardFocusPolicy.effectPickerTakesFocus { becomeFirstResponder() }
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    // MARK: Layout

    /// Draft bubble size (body + tail) for the picker preview.
    private var bubbleSize: CGSize {
        let t = ConversationTheme.self
        // The transcript's own bubble rule (85% between the margins, wider at AX sizes).
        let maxBubble = t.maxBubbleWidth(forAvailableWidth: view.bounds.width - 2 * margin)
        let measured = MessageCellLayout.measure(stage.label.attributedText ?? text, maxWidth: maxBubble - 2 * t.bubbleHorizontalPadding)
        let lines = min(CGFloat(Self.previewLineLimit), max(1, round(measured.height / t.lineHeight)))
        let textHeight = lines * t.lineHeight
        let body = max(measured.width + 2 * t.bubbleHorizontalPadding, t.minBubbleWidth)
        return CGSize(width: body + t.tailWidth, height: textHeight + 2 * t.bubbleVerticalPadding)
    }

    private var margin: CGFloat { view.directionalLayoutMargins.trailing }
    /// Messages' ink for the title and the effects' names: gray 90, or white
    /// at 80% in dark mode.
    static let secondaryInk = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.8) : UIColor(white: 90 / 255, alpha: 1) }

    /// Everything hangs off the send button where the long press found it.
    private var geometry: EffectPickerGeometry {
        var send = view.convert(sendButtonFrame, from: nil)
        if send.width <= 0 {
            send = CGRect(x: view.bounds.width - margin - 38, y: view.bounds.height - view.safeAreaInsets.bottom - 34, width: 38, height: 28)
        }
        return EffectPickerGeometry(sendButton: send, width: view.bounds.width, safeTop: view.safeAreaInsets.top, effectCount: rows.count)
    }

    private var cancelCenter: CGPoint { CGPoint(x: geometry.cancel.midX, y: geometry.cancel.midY) }

    private var homeBubbleFrame: CGRect { geometry.homeBubble(size: bubbleSize) }

    private func slotFrame(for effect: ConversationMessageEffect?) -> CGRect {
        guard let effect, mode == .bubble, let index = ConversationMessageEffect.bubbleEffects.firstIndex(of: effect) else { return homeBubbleFrame }
        return geometry.pickedBubble(size: bubbleSize, index: index)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdrop.frame = view.bounds
        backdropWash.frame = view.bounds
        screenPreview.frame = view.bounds
        let g = geometry
        titleLabel.frame = g.title
        modeControl.frame = g.segments
        cancelButton.frame = g.cancel
        track.frame = g.track
        let picked = selectedBubbleEffect.flatMap { ConversationMessageEffect.bubbleEffects.firstIndex(of: $0) }
        for (index, row) in rows.enumerated() {
            let dot = g.dots[index]
            row.dot.frame = dot
            let size = row.labelButton.intrinsicContentSize
            var labelFrame = CGRect(x: g.labelTrailing - size.width, y: dot.midY - size.height / 2, width: size.width, height: size.height)
            if index == picked {
                // The picked effect's name rides above the draft bubble.
                labelFrame.origin.y = EffectPickerGeometry.pickedLabelCenterY(bubble: slotFrame(for: row.effect)) - size.height / 2
            }
            row.labelButton.frame = labelFrame
        }
        if stage.layer.animation(forKey: "messageEffect") == nil {
            placeStage(slotFrame(for: selectedBubbleEffect))
        }
        pager.frame = view.bounds
        pager.contentSize = CGSize(width: view.bounds.width * CGFloat(pageLabels.count), height: view.bounds.height)
        for (index, label) in pageLabels.enumerated() {
            label.frame = CGRect(x: CGFloat(index) * view.bounds.width + 20, y: modeControl.frame.maxY + 18, width: view.bounds.width - 40, height: 22)
        }
        pageControl.sizeToFit()
        pageControl.center = CGPoint(x: view.bounds.midX, y: homeBubbleFrame.minY - 26)
        screenSendButton.bounds = CGRect(x: 0, y: 0, width: EffectPickerGeometry.dotSize, height: EffectPickerGeometry.dotSize)
        screenSendButton.center = CGPoint(x: g.cancel.midX, y: homeBubbleFrame.minY - 26)
        view.bringSubviewToFront(pager)
        for control in [titleLabel, modeControl, pageControl, screenSendButton, cancelButton] as [UIView] { view.bringSubviewToFront(control) }
    }

    private func placeStage(_ frame: CGRect) {
        let t = ConversationTheme.self
        let size = MessageCellLayout.measure(stage.label.attributedText ?? text, maxWidth: frame.width - t.tailWidth - 2 * t.bubbleHorizontalPadding)
        let body = CGRect(x: frame.minX, y: frame.minY, width: frame.width - t.tailWidth, height: frame.height)
        let textFrame = CGRect(
            x: body.minX + (body.width - size.width) / 2,
            y: body.minY + t.bubbleVerticalPadding - t.bodyGlyphLift,
            width: size.width,
            height: frame.height - 2 * t.bubbleVerticalPadding
        )
        stage.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        stage.configure(side: .trailing, tail: true, fill: t.outgoingBubble, text: stage.label.attributedText ?? text, bubbleFrame: frame, textFrame: textFrame)
        if stage.ink != nil { stage.setInk(true, outgoing: true) }
    }

    // MARK: Bubble mode

    private func dotTapped(_ effect: ConversationMessageEffect) {
        if selectedBubbleEffect == effect {
            send(effect)
        } else {
            select(effect)
        }
    }

    func select(_ effect: ConversationMessageEffect) {
        let changed = selectedBubbleEffect != effect
        selectedBubbleEffect = effect
        UISelectionFeedbackGenerator().selectionChanged()
        for row in rows { row.setSelected(row.effect == effect) }
        view.setNeedsLayout()
        stage.layer.removeAnimation(forKey: "messageEffect")
        stage.setInk(false, outgoing: true)
        let target = slotFrame(for: effect)
        let play = { [weak self] in
            guard let self, self.selectedBubbleEffect == effect, self.mode == .bubble else { return }
            if effect == .invisibleInk {
                self.stage.setInk(true, outgoing: true)
            } else {
                self.stage.play(effect, side: .trailing, reduceMotion: self.reduceMotion) {}
            }
        }
        guard changed else { play(); return }
        UIView.animate(withDuration: reduceMotion ? 0 : 0.32, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.placeStage(target)
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        } completion: { _ in play() }
    }

    // MARK: Screen mode

    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        modeControl.selectedSegmentIndex = mode.rawValue
        let isScreen = mode == .screen
        stage.layer.removeAnimation(forKey: "messageEffect")
        stage.setInk(false, outgoing: true)
        for row in rows {
            row.dot.isHidden = isScreen
            row.labelButton.isHidden = isScreen
        }
        track.isHidden = isScreen
        pager.isHidden = !isScreen
        pageControl.isHidden = !isScreen
        screenSendButton.isHidden = !isScreen
        UIView.animate(withDuration: 0.25) {
            self.screenPreview.alpha = isScreen ? 1 : 0
            self.placeStage(self.slotFrame(for: isScreen ? nil : self.selectedBubbleEffect))
        }
        if isScreen {
            playScreenPreview()
        } else {
            previewGeneration += 1
            screenPreview.stop()
            if let selected = selectedBubbleEffect { select(selected) }
        }
    }

    private func scrollToPage(_ page: Int, animated: Bool) {
        pager.setContentOffset(CGPoint(x: CGFloat(page) * pager.bounds.width, y: 0), animated: animated)
        if !animated { pageSettled() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { pageSettled() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { pageSettled() }

    private func pageSettled() {
        let page = Int(round(pager.contentOffset.x / max(1, pager.bounds.width)))
        guard page != screenPage || !screenPreview.isPlaying else { return }
        screenPage = max(0, min(page, ConversationMessageEffect.screenEffects.count - 1))
        pageControl.currentPage = screenPage
        UISelectionFeedbackGenerator().selectionChanged()
        playScreenPreview()
    }

    /// Plays the current page's effect, looping until the page or mode changes.
    private func playScreenPreview() {
        previewGeneration += 1
        let generation = previewGeneration
        let effect = ConversationMessageEffect.screenEffects[screenPage]
        let anchor = homeBubbleFrame
        screenPreview.play(effect, anchor: anchor, bubble: { [weak self] in self?.bubbleCopy() }) { [weak self] in
            guard let self, self.previewGeneration == generation, self.mode == .screen, self.presentingViewController != nil else { return }
            self.playScreenPreview()
        }
    }

    private func bubbleCopy() -> UIView {
        let copy = MessageBubbleStage()
        let frame = homeBubbleFrame
        copy.configure(side: .trailing, tail: true, fill: ConversationTheme.outgoingBubble, text: stage.label.attributedText ?? text, bubbleFrame: frame, textFrame: stage.label.frame.offsetBy(dx: frame.minX, dy: frame.minY))
        copy.label.numberOfLines = Self.previewLineLimit
        return copy
    }

    // MARK: Actions

    private func send(_ effect: ConversationMessageEffect) {
        previewGeneration += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSend?(effect)
    }

    private func cancel() {
        previewGeneration += 1
        onCancel?()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        renderBackdrop(afterScreenUpdates: false)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle, backdrop.image != nil else { return }
        renderBackdrop(afterScreenUpdates: true)
    }

    /// The conversation behind holds still while the picker is up, so one
    /// small snapshot carries Messages' radius-64 blur, which no public
    /// material reaches. Reduce Transparency keeps the system material.
    private func renderBackdrop(afterScreenUpdates: Bool) {
        if !UIAccessibility.isReduceTransparencyEnabled,
           let source = backdropSource,
           let image = Self.blurredSnapshot(of: source, afterScreenUpdates: afterScreenUpdates) {
            backdrop.image = image
            backdropMaterial?.removeFromSuperview()
            backdropMaterial = nil
            return
        }
        guard backdropMaterial == nil else { return }
        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        material.frame = view.bounds
        material.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(material, aboveSubview: backdrop)
        backdropMaterial = material
    }

    private var backdropMaterial: UIVisualEffectView?

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func blurredSnapshot(of source: UIView, afterScreenUpdates: Bool) -> UIImage? {
        let bounds = source.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(for: source.traitCollection)
        format.scale = EffectPickerBackdrop.renderScale
        format.opaque = true
        let snapshot = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            UIColor.systemBackground.resolvedColor(with: source.traitCollection).setFill()
            context.fill(bounds)
            source.drawHierarchy(in: bounds, afterScreenUpdates: afterScreenUpdates)
        }
        guard let cgImage = snapshot.cgImage else { return nil }
        let content = CIImage(cgImage: cgImage)
        let extent = content.extent
        let tint = EffectPickerBackdrop.tint
        let blend = CIFilter.linearLightBlendMode()
        blend.inputImage = CIImage(color: CIColor(red: tint.red / 255, green: tint.green / 255, blue: tint.blue / 255, alpha: tint.alpha)).cropped(to: extent)
        blend.backgroundImage = content
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = blend.outputImage?.clampedToExtent()
        blur.radius = Float(EffectPickerBackdrop.pixelRadius)
        guard let output = blur.outputImage?.cropped(to: extent),
              let rendered = ciContext.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: rendered, scale: EffectPickerBackdrop.renderScale, orientation: .up)
    }

    override func accessibilityPerformEscape() -> Bool {
        cancel()
        return true
    }
}

/// One bubble effect option: its name and the dot that turns into the send
/// button when the option is selected.
@MainActor
private final class EffectRow {
    let effect: ConversationMessageEffect
    let labelButton = UIButton(type: .custom)
    let dot = EffectSendButton()

    init(effect: ConversationMessageEffect) {
        self.effect = effect
        // Messages: the name in 11 pt semibold capitals, gray 90.
        labelButton.setTitle(effect.localizedName.localizedUppercase, for: .normal)
        labelButton.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        labelButton.setTitleColor(MessageEffectPickerViewController.secondaryInk, for: .normal)
        labelButton.contentHorizontalAlignment = .trailing
        labelButton.accessibilityIdentifier = "conversation.effects.\(effect.rawValue)"
        dot.accessibilityLabel = effect.localizedName
        dot.accessibilityIdentifier = "conversation.effects.dot.\(effect.rawValue)"
        labelButton.isAccessibilityElement = false
    }

    /// `selected` nil: nothing picked yet. Messages names the picked effect
    /// "SEND WITH …" and dims the others to 40%.
    func setSelected(_ selected: Bool?) {
        let name = selected == true
            ? String(format: String(localized: "conversation.effect.sendWithNamed", defaultValue: "Send with %@", bundle: .module), effect.localizedName)
            : effect.localizedName
        labelButton.setTitle(name.localizedUppercase, for: .normal)
        labelButton.alpha = selected == false ? 0.4 : 1
        let selected = selected == true
        UIView.animate(withDuration: 0.2) { self.dot.isSelectedForSend = selected }
        dot.accessibilityLabel = selected
            ? String(format: String(localized: "conversation.effect.sendWithNamed", defaultValue: "Send with %@", bundle: .module), effect.localizedName)
            : effect.localizedName
    }
}

/// A 9 pt gray dot that becomes Messages' blue send pill (38 x 28, white
/// arrow) in its 38 pt slot.
final class EffectSendButton: UIButton {
    var isSelectedForSend = false { didSet { update() } }
    private let dotView = UIView()
    private let pill = UIView()
    private let arrow = UIImageView(image: UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Gray 153 on the white track; in dark mode Messages adds gray 51 to
        // the track (plus-lighter), about white at 22% over it.
        dotView.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.22) : UIColor(white: 153 / 255, alpha: 1) }
        dotView.isUserInteractionEnabled = false
        addSubview(dotView)
        pill.backgroundColor = ConversationTheme.outgoingBubble
        pill.layer.cornerCurve = .continuous
        pill.isUserInteractionEnabled = false
        addSubview(pill)
        arrow.tintColor = .white
        arrow.contentMode = .center
        arrow.isUserInteractionEnabled = false
        pill.addSubview(arrow)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let d: CGFloat = 9
        dotView.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        dotView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        dotView.layer.cornerRadius = d / 2
        pill.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, 28))
        pill.center = CGPoint(x: bounds.midX, y: bounds.midY)
        pill.layer.cornerRadius = pill.bounds.height / 2
        arrow.frame = pill.bounds
    }

    private func update() {
        pill.alpha = isSelectedForSend ? 1 : 0
        pill.transform = isSelectedForSend ? .identity : CGAffineTransform(scaleX: 0.3, y: 0.3)
        dotView.alpha = isSelectedForSend ? 0 : 1
    }
}
#endif
