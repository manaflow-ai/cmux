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
    /// `CKInlineReplyTranscriptBackgroundColor` and the system-background
    /// tint, folded into one wash (`ConversationVeilBlur.reply`).
    let dim = UIView()
    let content = UIScrollView()
    var contentHeight: CGFloat = 0
    /// The bubble that lifts out of the transcript and settles back into it.
    var anchorMessageID: String?
    /// The thread's root message.
    var rootID: String?
    /// The thread's messages as last laid out (a store change that leaves
    /// them alone leaves the thread alone).
    var messages: [ConversationMessage] = []
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
        dim.backgroundColor = UIColor.resolving {
            let veil = ConversationVeilBlur.reply(dark: $0.userInterfaceStyle == .dark)
            return UIColor(white: veil.washWhite, alpha: veil.washAlpha)
        }
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

    /// ChatKit's background is a pure radius-10 blur. UIKit has no public
    /// pure blur, so a paused animator holds the ultra-thin material at the
    /// share that matches (`ConversationVeilBlur.reply`).
    func setBlur(_ amount: CGFloat) {
        let veil = ConversationVeilBlur.reply(dark: traitCollection.userInterfaceStyle == .dark)
        if blurAnimator == nil {
            let animator = UIViewPropertyAnimator(duration: 1, curve: .linear)
            animator.addAnimations { [blur] in blur.effect = UIBlurEffect(style: .systemUltraThinMaterial) }
            animator.pausesOnCompletion = true
            blurAnimator = animator
        }
        blurAnimator?.fractionComplete = max(0.0001, min(1, amount * veil.materialShare))
    }
}

/// A row about to travel: where its frame sits, where it starts and ends
/// (its superview's space) and the swipe offset it unwinds.
private typealias ReplyThreadRow = (view: UIView, baseY: CGFloat, startY: CGFloat, targetY: CGFloat, initialOffsetX: CGFloat)

/// One thread row's trip, in its superview's space: `baseY` is where its
/// frame sits (the transform carries it from there), `trip.y` where it
/// shows. The anchor (a swiped bubble) also unwinds its release offset.
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
        overlay.rootID = rootID
        overlay.onClose = { [weak self] in self?.exitReplyMode() }
        // The host material also blurs reply copies as they scroll under the
        // floating header; do not clip the thread at the name capsule.
        view.insertSubview(overlay, belowSubview: headerMaterial.superview == nil ? composerContainer : headerMaterial)
        // The thread's own interactive dismissal moves the composer too.
        keyboardDock.trackInteractiveDismissal(of: overlay.content)
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

    private func threadMessages(rootID: String) -> [ConversationMessage] {
        store.messages.filter { $0.id == rootID || $0.replyToID == rootID }
    }

    /// `followsBottom` false keeps the thread where the reader scrolled it.
    private func populate(_ overlay: ReplyThreadOverlay, rootID: String, followsBottom: Bool = true) {
        overlay.content.subviews.forEach { $0.removeFromSuperview() }
        let thread = threadMessages(rootID: rootID)
        overlay.messages = thread
        var models = ConversationRowBuilder.rows(store: store).compactMap { row -> MessageRowModel? in
            guard case var .message(model) = row, thread.contains(where: { $0.id == model.message.id }) else { return nil }
            // Inside the thread, replies render without their quote.
            model.replyQuote = nil
            model.showsTail = true
            // Names are a group's: a 1:1 thread shows none, as its transcript.
            model.showsSenderName = model.isGroup && !model.isOutgoing
            model.showsAvatar = model.reservesAvatarColumn
            model.message.replyCount = 0
            return model
        }
        // The thread is its own transcript, so its run plan places the
        // delivery status: under the thread's newest delivered message of
        // mine, even when the main transcript shows it on a later one.
        let plan = ConversationRunPlan(messages: thread, meID: store.meID)
        let isGroup = store.info?.kind == .group
        for index in models.indices {
            guard let position = thread.firstIndex(where: { $0.id == models[index].message.id }) else { continue }
            models[index].footer = ConversationRowBuilder.footer(for: plan.entries[position].status, isGroup: isGroup)
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
            // As in the transcript: the first row starts `nextRowGap` under the heading.
            y += TimestampCell.height + TimestampCell.nextRowGap
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
        layoutReplyOverlay(followsBottom: followsBottom)
    }

    /// Thread rows sit as they would in a transcript: a run from one sender
    /// closes up, a change of sender opens the gap.
    private static func threadRowSpacing(after previous: MessageRowModel, before next: MessageRowModel) -> CGFloat {
        previous.message.senderID == next.message.senderID ? 4 : 10
    }

    /// Keeps the thread bottom-aligned just above the composer as the
    /// keyboard moves and the draft grows: Messages moves the thread with
    /// each line added to or removed from the draft in the same frame as
    /// the field, keeping the bottom bubble 16.7 pt above it, and jumps it
    /// to the risen keyboard's layout at once (iOS 26.5 and 27.0).
    /// The thread stays at its end only when the reader was there (or
    /// `followsBottom` says so: opening, a reply of mine); a reader scrolled
    /// up keeps their place through header, field and keyboard changes.
    func layoutReplyOverlay(followsBottom: Bool? = nil) {
        guard let overlay = replyOverlay else { return }
        let content = overlay.content
        let wasAtBottom = content.bounds.height == 0
            || content.contentOffset.y >= content.contentSize.height - content.bounds.height - 1
        let followsBottom = followsBottom ?? wasAtBottom
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
            let bottom = max(-inset, y - available)
            let offset = followsBottom ? bottom : min(max(-inset, overlay.content.contentOffset.y), bottom)
            overlay.content.contentOffset = CGPoint(x: 0, y: offset)
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

    /// The open thread follows the store: Messages keeps the thread open
    /// after a reply is sent, so the reply joins it right above the field it
    /// left and the rows above move up on the thread's layout dynamics, with
    /// the composer still in reply mode (iOS 27.0). An incoming reply or a
    /// delivery status lands the same way.
    func refreshReplyThread() {
        guard let overlay = replyOverlay, overlay.isUserInteractionEnabled, let rootID = overlay.rootID else { return }
        guard store.messages.contains(where: { $0.id == rootID && !$0.isUnsent }) else {
            // The root was unsent or left the loaded window: nothing to reply to.
            exitReplyMode()
            return
        }
        let thread = threadMessages(rootID: rootID)
        guard thread != overlay.messages else { return }
        let fieldFrame = composer.fieldFrame(in: view)
        let before = threadScreenTops(in: overlay)
        // A swiped bubble still unwinding keeps its swing through the refresh.
        var swings: [String: CGFloat] = [:]
        for item in overlay.motion?.items ?? [] {
            if let id = (item.view as? MessageCell)?.model?.message.id, item.trip.offsetX != 0 { swings[id] = item.trip.offsetX }
        }
        overlay.motion?.stop()
        // The thread follows a reply of mine, or a reader already at its end;
        // a status or tapback landing while they read further up leaves them there.
        let known = Set(overlay.messages.map(\.id))
        let sentByMe = thread.contains { !known.contains($0.id) && $0.senderID == store.meID }
        let content = overlay.content
        let atBottom = content.contentOffset.y >= content.contentSize.height - content.bounds.height - 1
        let focused = focusedThreadMessageID(in: overlay)
        populate(overlay, rootID: rootID, followsBottom: sentByMe || atBottom)
        overlay.hiddenMessageIDs = Set(overlay.content.subviews.compactMap { ($0 as? MessageCell)?.model?.message.id })
        refreshReplyBacking(hiddenOnly: true)
        // The rows were rebuilt: VoiceOver stays on the message it was reading.
        if let focused {
            // Elements live on the content view (MessageCellAccessibility); a
            // message that left the thread hands focus back to VoiceOver.
            let cell = overlay.content.subviews.lazy.compactMap { $0 as? MessageCell }.first { $0.model?.message.id == focused }
            UIAccessibility.post(notification: .layoutChanged, argument: cell.map { $0.contentView.accessibilityElements?.first ?? $0 })
        }
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let fieldTop = overlay.content.convert(CGPoint(x: 0, y: fieldFrame.minY), from: view).y
        let rows = overlay.content.subviews.compactMap { view -> ReplyThreadRow? in
            guard view is MessageCell || view is TimestampCell else { return nil }
            let target = view.frame.minY
            let start: CGFloat
            if let id = (view as? MessageCell)?.model?.message.id, let top = before[id] {
                start = overlay.content.convert(CGPoint(x: 0, y: top), from: nil).y
            } else if view is TimestampCell, let top = before[Self.threadHeadingKey] {
                start = overlay.content.convert(CGPoint(x: 0, y: top), from: nil).y
            } else {
                // The new reply rises from the field it was typed in.
                let bubbleTop = (view as? MessageCell)?.cellLayout?.contentFrame.minY ?? 0
                start = max(target, fieldTop - bubbleTop)
            }
            let swing = (view as? MessageCell)?.model.flatMap { swings[$0.message.id] } ?? 0
            return (view: view, baseY: target, startY: start, targetY: target, initialOffsetX: swing)
        }
        let motion = ReplyThreadMotion(rows: rows, animatingOut: false, viewHeight: view.bounds.height, scale: traitCollection.displayScale)
        overlay.motion = motion
        motion.start()
    }

    /// The thread message VoiceOver is on, if its focus is inside the thread.
    private func focusedThreadMessageID(in overlay: ReplyThreadOverlay) -> String? {
        guard UIAccessibility.isVoiceOverRunning,
              let focused = UIAccessibility.focusedElement(using: .notificationVoiceOver) else { return nil }
        let container = (focused as? UIAccessibilityElement)?.accessibilityContainer as? UIView ?? focused as? UIView
        for case let cell as MessageCell in overlay.content.subviews where container?.isDescendant(of: cell) == true {
            return cell.model?.message.id
        }
        return nil
    }

    private static let threadHeadingKey = "\u{0}heading"

    /// Where each thread row's top shows now (window space), by message id.
    private func threadScreenTops(in overlay: ReplyThreadOverlay) -> [String: CGFloat] {
        var tops: [String: CGFloat] = [:]
        for view in overlay.content.subviews {
            let top = view.convert(CGPoint.zero, to: nil).y
            if let id = (view as? MessageCell)?.model?.message.id {
                tops[id] = top
            } else if view is TimestampCell {
                tops[Self.threadHeadingKey] = top
            }
        }
        return tops
    }

    /// The thread's rows return to their transcript twins (Reduce Motion:
    /// the thread fades).
    func exitReplyMode() {
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
        let settles = !UIAccessibility.isReduceMotionEnabled
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
