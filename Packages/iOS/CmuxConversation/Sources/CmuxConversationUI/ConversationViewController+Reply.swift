#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// Reply mode, as Messages' `CKInlineReplyChatController` draws it: the
/// transcript blurs behind a white (dark: black) veil, the thread (root plus
/// loaded replies) renders sharp just above the composer, the composer reads
/// "Reply", and the header trades its back button for an X.
///
/// The thread's rows are live copies that start exactly over their
/// transcript rows (whose originals hide) and glide into place with
/// ChatKit's per-frame layout dynamics; a swiped bubble carries its release
/// offset and unwinds it on the way. Closing runs the same dynamics back.
final class ReplyThreadOverlay: UIView {
    let blur = UIVisualEffectView(effect: nil)
    /// `CKInlineReplyTranscriptBackgroundColor`: white 60 % (dark: black 40 %).
    let dim = UIView()
    let content = UIScrollView()
    var contentHeight: CGFloat = 0
    /// The bubble that lifts out of the transcript and settles back into it.
    var anchorMessageID: String?
    var onClose: (() -> Void)?
    /// Thread messages whose transcript rows hide while their copies show.
    var hiddenMessageIDs: Set<String> = []
    /// While true the transcript behind shows outgoing text at 0.7 and attachments at 0.4.
    var dimsBacking = false
    fileprivate var motion: ReplyThreadMotion?
    private var blurAnimator: UIViewPropertyAnimator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "conversation.replyThread"
        content.accessibilityLabel = String(localized: "conversation.ax.replyTranscript", defaultValue: "Reply transcript", bundle: .module)
        addSubview(blur)
        dim.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.4) : UIColor.white.withAlphaComponent(0.6) }
        dim.alpha = 0
        addSubview(dim)
        addSubview(content)
        content.alwaysBounceVertical = true
        content.keyboardDismissMode = .interactive
        content.clipsToBounds = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func removeFromSuperview() {
        motion?.stop()
        // A paused animator must be stopped before it is released.
        blurAnimator?.stopAnimation(true)
        blurAnimator = nil
        super.removeFromSuperview()
    }

    override func accessibilityPerformEscape() -> Bool {
        onClose?()
        return true
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: content)
        let hitsMessage = content.subviews.contains { $0.frame.contains(point) && ($0 as? MessageCell)?.liftedContentFrame.offsetBy(dx: $0.frame.minX, dy: $0.frame.minY).contains(point) == true }
        if !hitsMessage { onClose?() }
    }

    /// ChatKit's background is a radius-10 blur plus a 9 % system-background
    /// wash. UIKit has no public radius, so a paused animator holds the light
    /// (dark) blur style at the share of its strength that matches.
    func setBlur(_ amount: CGFloat) {
        if blurAnimator == nil {
            let animator = UIViewPropertyAnimator(duration: 1, curve: .linear)
            let style: UIBlurEffect.Style = traitCollection.userInterfaceStyle == .dark ? .dark : .light
            animator.addAnimations { [blur] in blur.effect = UIBlurEffect(style: style) }
            animator.pausesOnCompletion = true
            blurAnimator = animator
        }
        blurAnimator?.fractionComplete = max(0.0001, min(1, amount * Self.blurShareOfStyle))
    }

    /// Share of the light style's blur that matches ChatKit's radius 10
    /// (calibrated against Messages' blurred bubbles on iOS 26.5 and 27.0).
    static let blurShareOfStyle: CGFloat = 1.0 / 3.0
}

/// One thread row's trip, in its superview's space: `baseY` is where its
/// frame sits (the transform carries it from there), `trip.y` where it
/// shows. The anchor (a swiped bubble) also unwinds its release offset.
/// A row about to travel: where its frame sits, where it starts and ends
/// (its superview's space) and the swipe offset it unwinds.
private typealias ReplyThreadRow = (view: UIView, baseY: CGFloat, startY: CGFloat, targetY: CGFloat, initialOffsetX: CGFloat)

private struct ReplyThreadItem {
    let view: UIView
    let baseY: CGFloat
    var trip: ReplyTrip
    var resting: Bool { trip.isResting }
}

/// Drives the thread's rows frame by frame (Messages' layout dynamics, see
/// `ReplyTrip`). A display link because UIKit has no animation of this
/// shape; it stops as soon as everything rests.
@MainActor
private final class ReplyThreadMotion: NSObject {
    private(set) var items: [ReplyThreadItem]
    let animatingOut: Bool
    var onRest: (() -> Void)?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    /// Each row goes from `startY` to `targetY` (its superview's space),
    /// the swiped one from `initialOffsetX`. Its easing is fixed here, once,
    /// from where it starts on screen; `viewHeight` is the conversation view's.
    init(rows: [ReplyThreadRow], animatingOut: Bool, viewHeight: CGFloat, scale: CGFloat) {
        let snap = ConversationReplyMotion.snapDistance(scale: scale, animatingOut: animatingOut)
        items = rows.map { row in
            let height = row.view.bounds.height
            let start = row.view.superview.map { $0.convert(CGPoint(x: 0, y: row.startY + height / 2), to: nil).y } ?? row.startY + height / 2
            let easing = ConversationReplyMotion.threadEasing(startCenterY: start, itemHeight: height, viewHeight: viewHeight, animatingOut: animatingOut)
            return ReplyThreadItem(view: row.view, baseY: row.baseY,
                                   trip: ReplyTrip(startY: row.startY, targetY: row.targetY, initialOffsetX: row.initialOffsetX, easing: easing, snapDistance: snap))
        }
        self.animatingOut = animatingOut
        super.init()
        apply()
    }

    func start() {
        guard link == nil else { return }
        if items.allSatisfy(\.resting) {
            onRest?()
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// The thread's container moved by `delta` (content space): rows keep
    /// their place on screen, so only their targets move. ChatKit lays the
    /// thread out for the risen keyboard at once rather than riding it up.
    func containerMoved(by delta: CGFloat) {
        guard delta != 0 else { return }
        for index in items.indices { items[index].trip.containerMoved(by: delta) }
        apply()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = lastTimestamp.map { link.timestamp - $0 } ?? 0
        lastTimestamp = link.timestamp
        let frame = elapsed > 0 ? elapsed : link.targetTimestamp - link.timestamp
        for index in items.indices { items[index].trip.step(frameDuration: frame) }
        apply()
        if items.allSatisfy(\.resting) {
            stop()
            onRest?()
        }
    }

    /// Never inside someone else's animation (the keyboard's layout pass).
    private func apply() {
        UIView.performWithoutAnimation(applyNow)
    }

    private func applyNow() {
        for item in items {
            let dy = item.trip.y - item.baseY
            if let cell = item.view as? MessageCell {
                cell.transform = CGAffineTransform(translationX: 0, y: dy)
                cell.replyDrag = item.trip.offsetX
                // Outgoing blue is anchored to the screen, so it shifts as the bubble travels.
                cell.updateScreenGradients()
            } else {
                item.view.transform = CGAffineTransform(translationX: item.trip.offsetX, y: dy)
            }
        }
    }
}

extension ConversationViewController {
    var replyOverlay: ReplyThreadOverlay? {
        view.subviews.compactMap { $0 as? ReplyThreadOverlay }.first
    }

    /// `dragOffset` is how far a swipe-to-reply had carried the bubble, so
    /// the thread's copy leaves from exactly where the finger let go.
    /// `anchorStart` is where the bubble shows right now (window space) when
    /// that isn't its transcript row: the long-press menu's lifted copy.
    func enterReplyMode(for message: ConversationMessage, dragOffset: CGFloat = 0, anchorStart: CGRect? = nil) {
        let rootID = message.replyToID ?? message.id
        openThread(rootID: rootID, replyTo: message, dragOffset: dragOffset, anchorStart: anchorStart)
    }

    func openThread(rootID: String, replyTo: ConversationMessage? = nil, dragOffset: CGFloat = 0, anchorStart: CGRect? = nil) {
        guard let root = store.message(id: rootID) else { return }
        // A thread still closing gives way at once.
        replyOverlay?.removeFromSuperview()
        replyTarget = replyTo ?? root
        let overlay = ReplyThreadOverlay(frame: view.bounds)
        overlay.onClose = { [weak self] in self?.exitReplyMode() }
        view.insertSubview(overlay, belowSubview: composerContainer)
        populate(overlay, rootID: rootID)
        composer.isReplyMode = true
        // Messages drops the back button at once and shows the X as the
        // background finishes settling.
        header.setBackHidden(true, animated: true, duration: Self.replyBackFade)
        header.setTrailingMode(.close, animated: true, delay: Self.replyCloseDelay, duration: Self.replyCloseFade)
        // The blurred transcript behind the thread is out of VoiceOver's reach.
        collectionView.accessibilityElementsHidden = true
        UIAccessibility.post(notification: .screenChanged, argument: overlay.content)
        let anchorID = (replyTo ?? root).id
        overlay.anchorMessageID = anchorID
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        var starts = reduceMotion ? [:] : transcriptOrigins(for: overlay)
        if !reduceMotion, let anchorStart,
           let copy = overlay.content.subviews.lazy.compactMap({ $0 as? MessageCell }).first(where: { $0.model?.message.id == anchorID }),
           let bubble = copy.cellLayout?.contentFrame {
            starts[ObjectIdentifier(copy)] = overlay.content.convert(anchorStart, from: nil).minY - bubble.minY
        }
        let rows = threadRows(in: overlay, starts: starts, anchorID: anchorID, anchorOffset: reduceMotion ? 0 : dragOffset)
        // The originals hide while their copies stand in for them.
        overlay.hiddenMessageIDs = Set(overlay.content.subviews.compactMap { ($0 as? MessageCell)?.model?.message.id })
        overlay.dimsBacking = true
        refreshReplyBacking(hiddenOnly: true)
        let chrome = threadOnlyChrome(of: anchorID, in: overlay)
        chrome.forEach { $0.alpha = 0 }
        if reduceMotion { overlay.content.alpha = 0 }
        let motion = ReplyThreadMotion(rows: rows, animatingOut: false, viewHeight: view.bounds.height, scale: traitCollection.displayScale)
        overlay.motion = motion
        motion.start()
        composer.textView.becomeFirstResponder()
        animateReplyBlur(overlay, entering: true)
        UIView.animate(withDuration: ConversationReplyMotion.backgroundDuration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            overlay.dim.alpha = 1
            overlay.content.alpha = 1
            chrome.forEach { $0.alpha = 1 }
            self.refreshReplyBacking(hiddenOnly: false)
        }
    }

    /// The blur over 0.3 s on UIKit's default ease in-out. The paused
    /// animator's fraction can't ride a UIView animation, so a display link
    /// samples the same curve.
    private func animateReplyBlur(_ overlay: ReplyThreadOverlay, entering: Bool, completion: (() -> Void)? = nil) {
        let driver = ReplyBlurDriver(duration: ConversationReplyMotion.backgroundDuration, from: entering ? 0 : 1, to: entering ? 1 : 0) { [weak overlay] value in
            overlay?.setBlur(value)
        }
        driver.completion = completion
        driver.start()
    }

    /// The sender name and avatar the thread shows on the anchor bubble but
    /// its transcript row doesn't (mid-run rows hide both); they fade so the
    /// lifted bubble matches its transcript row at both ends of the move.
    private func threadOnlyChrome(of messageID: String, in overlay: ReplyThreadOverlay) -> [UIView] {
        guard let copy = overlay.content.subviews.lazy.compactMap({ $0 as? MessageCell }).first(where: { $0.model?.message.id == messageID }),
              let index = rowIndex(ofMessage: messageID),
              case let .message(source) = rows[index] else { return [] }
        var views: [UIView] = []
        if !source.showsSenderName, !copy.senderLabel.isHidden { views.append(copy.senderLabel) }
        if !source.showsAvatar, !copy.avatar.isHidden { views.append(copy.avatar) }
        return views
    }

    private func rowIndex(ofMessage id: String) -> Int? {
        rows.firstIndex { if case let .message(model) = $0 { return model.message.id == id } else { return false } }
    }

    /// Where each thread row would sit to lie exactly over its transcript
    /// twin right now, in the thread's content space (twins on screen only).
    private func transcriptOrigins(for overlay: ReplyThreadOverlay) -> [ObjectIdentifier: CGFloat] {
        var origins: [ObjectIdentifier: CGFloat] = [:]
        var rootIndex: Int?
        for case let copy as MessageCell in overlay.content.subviews {
            guard let id = copy.model?.message.id, let index = rowIndex(ofMessage: id) else { continue }
            rootIndex = rootIndex ?? index
            guard let source = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? MessageCell,
                  let sourceBubble = source.cellLayout?.contentFrame, let copyBubble = copy.cellLayout?.contentFrame else { continue }
            // Bubble over bubble: the rows may differ above the bubble (name).
            let from = source.convert(sourceBubble, to: overlay.content)
            origins[ObjectIdentifier(copy)] = from.minY - copyBubble.minY
        }
        // The thread's time heading comes from the transcript's heading over the root.
        if let heading = overlay.content.subviews.first(where: { $0 is TimestampCell }), let rootIndex,
           let stampIndex = rows[..<rootIndex].lastIndex(where: { if case .timestamp = $0 { return true } else { return false } }),
           let stamp = collectionView.cellForItem(at: IndexPath(item: stampIndex, section: 0)) {
            origins[ObjectIdentifier(heading)] = stamp.convert(stamp.bounds, to: overlay.content).minY
        }
        return origins
    }

    /// Rows without a transcript twin travel with the anchor.
    private func threadRows(in overlay: ReplyThreadOverlay, starts: [ObjectIdentifier: CGFloat], anchorID: String, anchorOffset: CGFloat) -> [ReplyThreadRow] {
        let views = overlay.content.subviews.filter { $0 is MessageCell || $0 is TimestampCell }
        let anchor = views.first { ($0 as? MessageCell)?.model?.message.id == anchorID }
        let anchorShift = anchor.flatMap { view in starts[ObjectIdentifier(view)].map { $0 - view.frame.minY } } ?? 0
        return views.map { view in
            let target = view.frame.minY
            let start = starts[ObjectIdentifier(view)] ?? target + anchorShift
            let offset = view === anchor ? anchorOffset : 0
            return (view: view, baseY: target, startY: start, targetY: target, initialOffsetX: offset)
        }
    }

    private func populate(_ overlay: ReplyThreadOverlay, rootID: String) {
        overlay.content.subviews.forEach { $0.removeFromSuperview() }
        let thread = store.messages.filter { $0.id == rootID || $0.replyToID == rootID }
        var models = ConversationRowBuilder.rows(store: store).compactMap { row -> MessageRowModel? in
            guard case var .message(model) = row, thread.contains(where: { $0.id == model.message.id }) else { return nil }
            // Inside the thread, replies render without their quote.
            model.replyQuote = nil
            model.showsTail = true
            model.showsSenderName = !model.isOutgoing
            model.showsAvatar = model.reservesAvatarColumn
            model.message.replyCount = 0
            return model
        }
        // The thread is its own transcript: only its newest outgoing message
        // keeps a delivery status.
        let lastOutgoing = models.lastIndex { $0.isOutgoing }
        for index in models.indices where index != lastOutgoing && models[index].footer != .notDelivered {
            models[index].footer = .none
        }
        let width = view.bounds.width
        var y: CGFloat = 0
        // Messages heads the thread with its root's time, as a transcript would.
        if let first = models.first {
            let stamp = TimestampCell(frame: CGRect(x: 0, y: 0, width: width, height: TimestampCell.height))
            stamp.configure(date: first.message.sentAt)
            stamp.isUserInteractionEnabled = false
            overlay.content.addSubview(stamp)
            stamp.layoutIfNeeded()
            y += TimestampCell.height
        }
        for (index, model) in models.enumerated() {
            if index > 0 { y += Self.threadRowSpacing(after: models[index - 1], before: model) }
            let cellLayout = MessageCellLayout.compute(model: model, width: width, margin: layoutMargin, text: layoutCache.attributedText(for: model))
            let cell = MessageCell(frame: CGRect(x: 0, y: y, width: width, height: cellLayout.height))
            cell.configure(model: model, layout: cellLayout, text: layoutCache.attributedText(for: model))
            cell.replyIndicator.isHidden = true
            configureAccessibility(cell, model: model)
            overlay.content.addSubview(cell)
            cell.layoutIfNeeded()
            y += cellLayout.height
        }
        overlay.contentHeight = y
        layoutReplyOverlay()
    }

    /// Thread rows sit as they would in a transcript: a run from one sender
    /// closes up, a change of sender opens the gap.
    private static func threadRowSpacing(after previous: MessageRowModel, before next: MessageRowModel) -> CGFloat {
        previous.message.senderID == next.message.senderID ? 4 : 10
    }

    /// Keeps the thread bottom-aligned just above the composer as the keyboard moves.
    func layoutReplyOverlay() {
        guard let overlay = replyOverlay else { return }
        overlay.frame = view.bounds
        overlay.blur.frame = overlay.bounds
        overlay.dim.frame = overlay.bounds
        let width = view.bounds.width
        let y = overlay.contentHeight
        let headerBottom = header.frame.maxY
        let available = composerContainer.frame.minY - headerBottom - Self.threadBottomGap
        // Where content-space 0 sits on screen, before and after.
        let before = overlay.content.frame.minY - overlay.content.contentOffset.y
        // The thread jumps to the composer's resting place (the keyboard's
        // final frame) instead of riding the keyboard's animation.
        UIView.performWithoutAnimation {
            overlay.content.frame = CGRect(x: 0, y: headerBottom, width: width, height: available)
            overlay.content.contentSize = CGSize(width: width, height: y)
            let inset = max(0, available - y)
            overlay.content.contentInset = UIEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
            overlay.content.contentOffset = CGPoint(x: 0, y: max(-inset, y - available))
        }
        let after = overlay.content.frame.minY - overlay.content.contentOffset.y
        overlay.motion?.containerMoved(by: after - before)
        for case let cell as MessageCell in overlay.content.subviews { cell.updateScreenGradients() }
    }

    /// Gap between the thread's last row and the composer field: Messages
    /// on an iPhone 17 Pro Max lands the last bubble's body 16.7 pt above
    /// the field's top edge (4 pt higher than the transcript keeps it).
    static let threadBottomGap: CGFloat = 6

    /// Transcript rows behind the blur: thread messages hide (their copies
    /// stand in), outgoing text dims to 0.7 and photos to 0.4 while the
    /// thread is up (ChatKit's `targetAlphaForChatItem:`).
    func refreshReplyBacking(hiddenOnly: Bool) {
        for case let cell as MessageCell in collectionView.visibleCells {
            guard let model = cell.model else { continue }
            applyReplyBacking(to: cell, model: model, hiddenOnly: hiddenOnly)
        }
    }

    func applyReplyBacking(to cell: MessageCell, model: MessageRowModel, hiddenOnly: Bool = false) {
        let overlay = replyOverlay
        let hidden = overlay?.hiddenMessageIDs.contains(model.message.id) == true
        var alpha: CGFloat = 1
        if overlay?.dimsBacking == true {
            if !model.message.attachments.isEmpty {
                alpha = ConversationReplyMotion.backingAttachmentAlpha
            } else if model.isOutgoing {
                alpha = ConversationReplyMotion.backingOutgoingTextAlpha
            }
        }
        // The bubble's own layer, so arrivals and send flights (which use
        // the content view) are untouched.
        if hidden {
            UIView.performWithoutAnimation { cell.shiftable.alpha = 0 }
        } else if !hiddenOnly || cell.shiftable.alpha == 0 {
            cell.shiftable.alpha = alpha
        }
    }

    /// `settling` returns the thread's rows to their transcript twins; a
    /// send passes false because the transcript scrolls to the new reply
    /// underneath, so the thread just fades as the reply flies in.
    func exitReplyMode(settling: Bool = true) {
        guard let overlay = replyOverlay, overlay.isUserInteractionEnabled else { return }
        overlay.isUserInteractionEnabled = false
        replyTarget = nil
        composer.isReplyMode = false
        // The X goes at once; the back button returns as the blur clears.
        header.setTrailingMode(isSelecting ? .cancel : .action, animated: true, duration: Self.replyBackFade)
        header.setBackHidden(isSelecting, animated: true, delay: ConversationReplyMotion.backgroundDuration, duration: Self.replyCloseFade)
        collectionView.accessibilityElementsHidden = false
        UIAccessibility.post(notification: .screenChanged, argument: nil)
        overlay.dimsBacking = false
        let settles = settling && !UIAccessibility.isReduceMotionEnabled
        if !settles {
            overlay.hiddenMessageIDs = []
            refreshReplyBacking(hiddenOnly: true)
        }
        var backgroundDone = false
        var motionDone = !settles
        let finish = { [weak self, weak overlay] in
            guard backgroundDone, motionDone, let overlay, overlay.superview != nil else { return }
            overlay.hiddenMessageIDs = []
            overlay.removeFromSuperview()
            self?.refreshReplyBacking(hiddenOnly: false)
        }
        var fading: [UIView] = []
        if settles {
            let targets = transcriptOrigins(for: overlay)
            let current = overlay.motion?.items ?? []
            overlay.motion?.stop()
            let rows = current.compactMap { item -> ReplyThreadRow? in
                guard let target = targets[ObjectIdentifier(item.view)] else {
                    fading.append(item.view)
                    return nil
                }
                return (view: item.view, baseY: item.baseY, startY: item.trip.y, targetY: target, initialOffsetX: 0)
            }
            let motion = ReplyThreadMotion(rows: rows, animatingOut: true, viewHeight: view.bounds.height, scale: traitCollection.displayScale)
            motion.onRest = {
                motionDone = true
                finish()
            }
            overlay.motion = motion
            motion.start()
        } else {
            overlay.motion?.stop()
        }
        animateReplyBlur(overlay, entering: false) {
            backgroundDone = true
            finish()
        }
        UIView.animate(withDuration: ConversationReplyMotion.backgroundDuration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            overlay.dim.alpha = 0
            if !settles { overlay.content.alpha = 0 }
            fading.forEach { $0.alpha = 0 }
            self.refreshReplyBacking(hiddenOnly: false)
        }
    }

    /// The back button's fade as the thread opens, and the X's as it closes.
    static let replyBackFade: TimeInterval = 0.06
    /// When the X starts to show and how long it fades in, measured on
    /// Messages: iOS 26.5 ~0.38 s then ~0.2 s; iOS 27.0 ~0.28 s then ~0.05 s.
    static var replyCloseDelay: TimeInterval {
        if #available(iOS 27, *) { return 0.27 }
        return 0.32
    }
    static var replyCloseFade: TimeInterval {
        if #available(iOS 27, *) { return 0.05 }
        return 0.2
    }
}

/// Samples UIKit's default ease in-out on a display link for a value UIKit
/// can't animate directly (the paused animator's blur fraction). Keeps
/// itself alive until it finishes.
@MainActor
private final class ReplyBlurDriver: NSObject {
    let duration: TimeInterval
    let from: CGFloat
    let to: CGFloat
    let apply: (CGFloat) -> Void
    var completion: (() -> Void)?
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval?
    private var retainedSelf: ReplyBlurDriver?

    init(duration: TimeInterval, from: CGFloat, to: CGFloat, apply: @escaping (CGFloat) -> Void) {
        self.duration = duration
        self.from = from
        self.to = to
        self.apply = apply
    }

    func start() {
        apply(from)
        retainedSelf = self
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let start = startTime ?? link.timestamp
        startTime = start
        let x = min(1, (link.targetTimestamp - start) / duration)
        apply(from + (to - from) * ConversationReplyMotion.easeInOut(CGFloat(x)))
        if x >= 1 {
            link.invalidate()
            self.link = nil
            completion?()
            retainedSelf = nil
        }
    }
}
#endif
