#if canImport(UIKit)
import CmuxConversationCore
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

    private let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let titleLabel = UILabel()
    private let modeControl = UISegmentedControl(items: [ConversationEffectStrings.bubble, ConversationEffectStrings.screen])
    private let cancelButton = UIButton(type: .custom)
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

    init(text: NSAttributedString, sendButtonFrame: CGRect, reduceMotion: Bool) {
        self.text = text
        self.sendButtonFrame = sendButtonFrame
        self.reduceMotion = reduceMotion
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
        view.addSubview(backdrop)

        screenPreview.alpha = 0
        view.addSubview(screenPreview)

        titleLabel.text = ConversationEffectStrings.sendWithEffect
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
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

        var cancel = UIButton.Configuration.filled()
        cancel.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        cancel.baseBackgroundColor = .tertiarySystemFill
        cancel.baseForegroundColor = .secondaryLabel
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
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    // MARK: Layout

    /// Draft bubble size (body + tail) for the picker preview.
    private var bubbleSize: CGSize {
        let t = ConversationTheme.self
        let maxBubble = floor(view.bounds.width * t.maxBubbleWidthFraction)
        let measured = MessageCellLayout.measure(stage.label.attributedText ?? text, maxWidth: maxBubble - 2 * t.bubbleHorizontalPadding)
        let lines = min(CGFloat(Self.previewLineLimit), max(1, round(measured.height / t.lineHeight)))
        let textHeight = lines * t.lineHeight
        let body = max(measured.width + 2 * t.bubbleHorizontalPadding, t.lineHeight + 2 * t.bubbleVerticalPadding)
        return CGSize(width: body + t.tailWidth, height: textHeight + 2 * t.bubbleVerticalPadding)
    }

    private var margin: CGFloat { view.directionalLayoutMargins.trailing }
    private static let dotSize: CGFloat = 30
    private static let rowLabelHeight: CGFloat = 20

    /// The cancel button's center (where the composer's send button was).
    private var cancelCenter: CGPoint {
        // The keyboard hides while the sheet is up, so the send button's
        // resting place is the composer row at the bottom safe area.
        let local = view.convert(sendButtonFrame, from: nil)
        let x = local.width > 0 ? local.midX : view.bounds.width - margin - Self.dotSize / 2
        return CGPoint(x: x, y: view.bounds.height - view.safeAreaInsets.bottom - 4 - ConversationTheme.composerMinHeight / 2)
    }

    private var homeBubbleFrame: CGRect {
        let size = bubbleSize
        let bottom = cancelCenter.y - Self.dotSize / 2 - 14
        return CGRect(x: view.bounds.width - margin - size.width + ConversationTheme.tailWidth, y: bottom - size.height, width: size.width, height: size.height)
    }

    /// Row label center y for each bubble effect, top (Slam) to bottom (Invisible Ink).
    private func rowCenterY(_ index: Int) -> CGFloat {
        let pitch = bubbleSize.height + 36
        let fromBottom = CGFloat(rows.count - 1 - index)
        return homeBubbleFrame.minY - 22 - fromBottom * pitch
    }

    private func slotFrame(for effect: ConversationMessageEffect?) -> CGRect {
        guard let effect, mode == .bubble, let index = ConversationMessageEffect.bubbleEffects.firstIndex(of: effect) else { return homeBubbleFrame }
        var frame = homeBubbleFrame
        frame.origin.y = rowCenterY(index) - Self.rowLabelHeight / 2 - 8 - frame.height
        return frame
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdrop.frame = view.bounds
        screenPreview.frame = view.bounds
        let top = view.safeAreaInsets.top
        titleLabel.frame = CGRect(x: 20, y: top + 12, width: view.bounds.width - 40, height: 22)
        let segmentWidth = min(260, view.bounds.width - 80)
        modeControl.frame = CGRect(x: (view.bounds.width - segmentWidth) / 2, y: titleLabel.frame.maxY + 12, width: segmentWidth, height: 32)
        cancelButton.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        cancelButton.center = cancelCenter
        let dotX = cancelCenter.x
        for (index, row) in rows.enumerated() {
            let y = rowCenterY(index)
            row.dot.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
            row.dot.center = CGPoint(x: dotX, y: y)
            let labelWidth: CGFloat = 200
            row.labelButton.frame = CGRect(x: dotX - Self.dotSize / 2 - 10 - labelWidth, y: y - Self.rowLabelHeight / 2, width: labelWidth, height: Self.rowLabelHeight)
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
        screenSendButton.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        screenSendButton.center = CGPoint(x: dotX, y: homeBubbleFrame.minY - 26)
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
        guard page != screenPage || screenPreview.layer.animation(forKey: "screenEffect") == nil else { return }
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
        labelButton.setTitle(effect.localizedName, for: .normal)
        labelButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        labelButton.setTitleColor(.secondaryLabel, for: .normal)
        labelButton.contentHorizontalAlignment = .trailing
        labelButton.accessibilityIdentifier = "conversation.effects.\(effect.rawValue)"
        dot.accessibilityLabel = effect.localizedName
        dot.accessibilityIdentifier = "conversation.effects.dot.\(effect.rawValue)"
        labelButton.isAccessibilityElement = false
    }

    func setSelected(_ selected: Bool) {
        labelButton.setTitleColor(selected ? .label : .secondaryLabel, for: .normal)
        UIView.animate(withDuration: 0.2) { self.dot.isSelectedForSend = selected }
        dot.accessibilityLabel = selected
            ? String(format: String(localized: "conversation.effect.sendWithNamed", defaultValue: "Send with %@", bundle: .module), effect.localizedName)
            : effect.localizedName
    }
}

/// A gray dot that becomes a blue send arrow.
final class EffectSendButton: UIButton {
    var isSelectedForSend = false { didSet { update() } }
    private let arrow = UIImageView(image: UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        arrow.tintColor = .white
        arrow.contentMode = .center
        arrow.isUserInteractionEnabled = false
        addSubview(arrow)
        layer.cornerCurve = .continuous
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        arrow.frame = bounds
    }

    private func update() {
        backgroundColor = isSelectedForSend ? ConversationTheme.outgoingBubble : UIColor.tertiarySystemFill
        arrow.alpha = isSelectedForSend ? 1 : 0
        transform = isSelectedForSend ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8)
    }
}
#endif
