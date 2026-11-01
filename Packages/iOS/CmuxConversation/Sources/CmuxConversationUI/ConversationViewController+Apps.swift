#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import Photos
import UIKit
import UniformTypeIdentifiers

/// The "+" apps menu: Messages' send menu popover. The "+" glass circle
/// itself grows into the menu (one glass shape whose frame, corner radius and
/// contents animate on ChatKit's springs) and shrinks back into the circle on
/// dismiss. Width and height ride separate springs, as in ChatKit, so the
/// shape stretches sideways a beat after it rises. See `SendMenuGeometry`.
final class AppsMenuOverlay: UIView {
    struct Item {
        var title: String
        var symbol: String
        var color: UIColor
        /// Drawn instead of `symbol` on `color` (Send Later's dashed clock).
        var customIcon: UIImage? = nil
        /// A full 54 pt row image drawn as is (Messages' app artwork, see
        /// `SendMenuIcons`), replacing `symbol`, `color` and `customIcon`.
        var artwork: UIImage? = nil
        var handler: () -> Void
    }

    private typealias G = SendMenuGeometry
    /// Groups the menu with the glass it grows out of, so the shapes blend
    /// as one (`UIGlassContainerEffect` on iOS 26 and later).
    private let glassContainer: UIVisualEffectView
    private let panel = makeGlassView(cornerRadius: ConversationTheme.plusButtonSize / 2, tint: ConversationTheme.systemMenuGlassTint)
    /// The rows at their open size, scaled to the panel's current size
    /// (horizontal and vertical scale on separate springs).
    private let contentX = UIView()
    private let contentY = UIView()
    private let rows = UIStackView()
    /// The "+" carried along inside the panel: it doubles and fades out.
    private let plusX = UIView()
    private let plusY = UIImageView()
    private let anchor: CGRect
    /// Top of the shown keyboard, which the menu stays above.
    var keyboardTop: CGFloat?
    private var openFrame: CGRect = .zero
    private var isDismissing = false
    /// Called once the menu has folded back into the "+" circle.
    var onDismissed: (() -> Void)?

    init(frame: CGRect, anchor: CGRect, plusImage: UIImage?, items: [Item]) {
        self.anchor = anchor
        if #available(iOS 26.0, *) {
            glassContainer = UIVisualEffectView(effect: UIGlassContainerEffect())
        } else {
            glassContainer = UIVisualEffectView(effect: nil)
        }
        super.init(frame: frame)
        accessibilityIdentifier = "conversation.appsMenu"
        accessibilityViewIsModal = true
        glassContainer.frame = bounds
        glassContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glassContainer)
        glassContainer.contentView.addSubview(panel)
        panel.contentView.addSubview(contentX)
        contentX.addSubview(contentY)
        rows.axis = .vertical
        contentY.addSubview(rows)
        panel.contentView.addSubview(plusX)
        plusX.addSubview(plusY)
        plusY.image = plusImage
        plusY.tintColor = .label
        plusY.contentMode = .center
        for item in items { rows.addArrangedSubview(makeRow(item)) }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeRow(_ item: Item) -> UIView {
        let row = UIButton(type: .custom)
        let iconSize = G.iconSize
        let icon: UIImageView
        if let artwork = item.artwork {
            icon = UIImageView(image: artwork)
        } else {
            icon = UIImageView(image: item.customIcon ?? UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: .semibold)))
            icon.tintColor = .white
            icon.backgroundColor = item.color
            icon.layer.cornerRadius = iconSize / 2
        }
        icon.contentMode = .center
        icon.frame = CGRect(x: G.iconLeading, y: (G.rowHeight - iconSize) / 2, width: iconSize, height: iconSize)
        row.addSubview(icon)
        let labelX = G.iconLeading + iconSize + G.iconToLabel
        // Centered in the row less 6 pt above and below, room for the larger
        // text sizes (Messages: a 54 pt label at AX3).
        let label = UILabel(frame: CGRect(x: labelX, y: 6, width: G.maximumWidth - labelX - 16, height: G.rowHeight - 12))
        label.text = item.title
        let title2 = UIFontMetrics(forTextStyle: .title2).scaledValue(for: G.labelFontSize)
        label.font = .systemFont(ofSize: G.labelPointSize(title2Scaled: title2))
        // `sendMenuListItemTextColor`, as measured on screen.
        let lightWhite = G.labelWhite(iOS27: SendMenuIcons.isIOS27)
        // Dark: ChatKit draws 70% white composited plus-lighter, which reads
        // 209 on the 30 gray panel (MobileSMS 26.5); a plain blend needs 80%.
        label.textColor = UIColor.resolving { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.8) : UIColor(white: lightWhite, alpha: 1) }
        // Messages truncates a long title ("Apple C..." at AX3).
        label.lineBreakMode = .byTruncatingTail
        row.addSubview(label)
        row.heightAnchor.constraint(equalToConstant: G.rowHeight).isActive = true
        row.accessibilityLabel = item.title
        row.accessibilityIdentifier = "conversation.apps.\(item.symbol)"
        row.addAction(UIAction { [weak self] _ in self?.dismiss(then: item.handler) }, for: .touchUpInside)
        row.configurationUpdateHandler = { button in
            button.backgroundColor = button.isHighlighted ? UIColor.label.withAlphaComponent(0.06) : .clear
        }
        return row
    }

    func present() {
        let insets = superview?.safeAreaInsets ?? .zero
        var iOS27 = false
        if #available(iOS 27, *) { iOS27 = true }
        openFrame = G.openFrame(anchor: anchor, in: bounds, safeArea: (insets.top, insets.left, insets.bottom, insets.right), itemCount: rows.arrangedSubviews.count, bottomInset: G.bottomInset(iOS27: iOS27), keyboardTop: keyboardTop)
        let size = openFrame.size
        for view in [contentX, contentY] { view.bounds = CGRect(origin: .zero, size: size) }
        contentY.center = CGPoint(x: size.width / 2, y: size.height / 2)
        rows.frame = CGRect(x: 0, y: G.verticalInset, width: size.width, height: CGFloat(rows.arrangedSubviews.count) * G.rowHeight)
        plusX.bounds = CGRect(origin: .zero, size: anchor.size)
        plusY.frame = plusX.bounds

        if UIAccessibility.isReduceMotionEnabled {
            state = .open
            apply(State.open, frame: openFrame)
            panel.alpha = 0
            UIView.animate(withDuration: 0.25) { self.panel.alpha = 1 }
            return
        }
        // The "+" circle, exactly: the menu starts as it.
        state = .closed
        apply(.closed, frame: anchor)
        animate(to: .open, frame: openFrame, springs: .present)
    }

    /// Folds the menu back into the "+" circle, then runs `completion`.
    func dismiss(then completion: (() -> Void)? = nil) {
        guard !isDismissing else { return }
        isDismissing = true
        isUserInteractionEnabled = false
        // An item opens its own UI as the menu closes, as in Messages.
        completion?()
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2) { self.panel.alpha = 0 } completion: { _ in self.finish() }
            return
        }
        animate(to: .closed, frame: anchor, springs: .dismiss) { [weak self] in self?.finish() }
    }

    private func finish() {
        removeFromSuperview()
        onDismissed?()
    }

    // MARK: Morph

    /// What the morph animates besides the frame.
    private struct State {
        var plusScale: CGFloat
        var plusAlpha: CGFloat
        var contentAlpha: CGFloat
        static let closed = State(plusScale: 1, plusAlpha: 1, contentAlpha: 0)
        static let open = State(plusScale: G.plusSymbolScale, plusAlpha: 0, contentAlpha: 1)
    }

    private struct Springs {
        var horizontal: G.Spring
        var vertical: G.Spring
        var plus: G.Spring
        var content: G.Spring
        /// Before the "+" fades and the rows fade in.
        var contentDelay: Double = 0
        static let present = Springs(horizontal: G.Present.horizontal, vertical: G.Present.vertical, plus: G.Present.plusFade, content: G.Present.content, contentDelay: G.Present.contentDelay)
        static let dismiss = Springs(horizontal: G.Dismiss.horizontal, vertical: G.Dismiss.vertical, plus: G.Dismiss.plusOpacity, content: G.Dismiss.content)
    }

    /// One spring-driven value, sampled every frame.
    private struct Track {
        var from: CGFloat
        var to: CGFloat
        var spring: G.Spring
        var delay: Double = 0
        func value(_ elapsed: Double) -> CGFloat { from + (to - from) * spring.progress(at: elapsed - spring.delay - delay) }
        func isDone(_ elapsed: Double) -> Bool { elapsed - spring.delay - delay >= spring.settlingDuration }
    }

    private struct Morph {
        /// Set by the first frame drawn, so building the menu costs no motion.
        var start: CFTimeInterval?
        var centerX, width, centerY, height, plusScaleX, plusScaleY, plusAlpha, contentAlpha: Track
        var completion: (() -> Void)?
    }

    private var morph: Morph?
    private var displayLink: CADisplayLink?
    private var state = State.closed
    private var currentFrame: CGRect = .zero

    private func animate(to target: State, frame: CGRect, springs: Springs, completion: (() -> Void)? = nil) {
        let from = currentFrame
        morph = Morph(
            start: nil,
            centerX: Track(from: from.midX, to: frame.midX, spring: springs.horizontal),
            width: Track(from: from.width, to: frame.width, spring: springs.horizontal),
            centerY: Track(from: from.midY, to: frame.midY, spring: springs.vertical),
            height: Track(from: from.height, to: frame.height, spring: springs.vertical),
            plusScaleX: Track(from: state.plusScale, to: target.plusScale, spring: springs.horizontal),
            plusScaleY: Track(from: state.plusScale, to: target.plusScale, spring: springs.vertical),
            plusAlpha: Track(from: state.plusAlpha, to: target.plusAlpha, spring: springs.plus, delay: springs.contentDelay),
            contentAlpha: Track(from: state.contentAlpha, to: target.contentAlpha, spring: springs.content, delay: springs.contentDelay),
            completion: completion
        )
        if displayLink == nil {
            let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    fileprivate func step() {
        guard var morph else { return }
        // Sample at the time the frame reaches the screen.
        let now = displayLink?.targetTimestamp ?? CACurrentMediaTime()
        if morph.start == nil {
            morph.start = now
            self.morph = morph
        }
        let elapsed = now - (morph.start ?? now)
        let width = morph.width.value(elapsed), height = morph.height.value(elapsed)
        let frame = CGRect(x: morph.centerX.value(elapsed) - width / 2, y: morph.centerY.value(elapsed) - height / 2, width: width, height: height)
        state = State(plusScale: morph.plusScaleY.value(elapsed), plusAlpha: morph.plusAlpha.value(elapsed), contentAlpha: morph.contentAlpha.value(elapsed))
        apply(state, frame: frame, plusScaleX: morph.plusScaleX.value(elapsed))
        let tracks = [morph.centerX, morph.width, morph.centerY, morph.height, morph.plusAlpha, morph.contentAlpha]
        if tracks.allSatisfy({ $0.isDone(elapsed) }) {
            self.morph = nil
            displayLink?.invalidate()
            displayLink = nil
            morph.completion?()
        }
    }

    private func stopMorph() {
        morph = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Lays the panel out at `frame`, its rows scaled from their open size.
    private func apply(_ state: State, frame: CGRect, plusScaleX: CGFloat? = nil) {
        currentFrame = frame
        UIView.performWithoutAnimation {
            panel.frame = frame
            panel.layer.cornerRadius = G.cornerRadius(for: frame.size, closed: anchor.size, open: openFrame.size)
            let mid = CGPoint(x: frame.width / 2, y: frame.height / 2)
            contentX.center = mid
            contentX.transform = CGAffineTransform(scaleX: max(frame.width / openFrame.width, 0.001), y: 1)
            contentY.transform = CGAffineTransform(scaleX: 1, y: max(frame.height / openFrame.height, 0.001))
            contentX.alpha = state.contentAlpha
            plusX.center = mid
            plusX.transform = CGAffineTransform(scaleX: plusScaleX ?? state.plusScale, y: 1)
            plusY.transform = CGAffineTransform(scaleX: 1, y: state.plusScale)
            plusX.alpha = state.plusAlpha
        }
    }

    /// Rows take their own touches; everywhere else belongs to the menu's
    /// tap and swipe (a glass container passes misses through on iOS 27).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, self.point(inside: point, with: event) else { return nil }
        if let hit = super.hitTest(point, with: event), hit.isDescendant(of: panel) { return hit }
        return self
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss()
        return true
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        if !panel.frame.contains(tap.location(in: self)) { dismiss() }
    }

    /// Swiping down (on the menu or around it) shrinks the menu toward the
    /// "+"; letting go far or fast enough closes it, otherwise it springs
    /// back open.
    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard !isDismissing, !UIAccessibility.isReduceMotionEnabled else { return }
        let translation = pan.translation(in: self).y
        switch pan.state {
        case .began:
            stopMorph()
        case .changed:
            let frame = G.draggedFrame(open: openFrame, anchor: anchor, translation: translation)
            apply(state, frame: frame)
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: self).y
            if pan.state == .ended, translation > 40 || velocity > 500 {
                dismiss()
            } else {
                animate(to: .open, frame: openFrame, springs: .present)
            }
        default:
            break
        }
    }
}

/// Breaks the display link's strong reference to the overlay.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var overlay: AppsMenuOverlay?
    init(_ overlay: AppsMenuOverlay) { self.overlay = overlay }
    @objc func tick() { overlay?.step() }
}

extension ConversationViewController {
    /// Camera (when the device has one), Photos and Files. Messages lists
    /// Camera and Photos first in the same artwork; it has no Files row, so
    /// Files is drawn in that style (`SendMenuIcons`). Audio stays on the
    /// composer's record button.
    func presentAppsMenu() {
        dismissPhotoDrawer()
        // Messages (iOS 26.5 and 27.0) keeps the keyboard up under the menu,
        // with the composer still riding it; items that need the keyboard's
        // place (Photos) dismiss it themselves.
        var items: [AppsMenuOverlay.Item] = []
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            items.append(.init(title: String(localized: "conversation.apps.camera", defaultValue: "Camera", bundle: .module), symbol: "camera.fill", color: .clear, artwork: SendMenuIcons.image(.camera)) { [weak self] in
                self?.presentCamera()
            })
        }
        items.append(.init(title: String(localized: "conversation.apps.photos", defaultValue: "Photos", bundle: .module), symbol: "photo.on.rectangle", color: .clear, artwork: SendMenuIcons.image(.photos)) { [weak self] in
            self?.presentPhotoDrawer()
        })
        items.append(.init(title: String(localized: "conversation.apps.files", defaultValue: "Files", bundle: .module), symbol: "folder.fill", color: .clear, artwork: SendMenuIcons.image(.files)) { [weak self] in
            self?.presentFilePicker()
        })
        view.layoutIfNeeded()
        let anchor = composer.plusGlassFrame(in: view)
        let overlay = AppsMenuOverlay(frame: view.bounds, anchor: anchor, plusImage: composer.plusButton.image(for: .normal), items: items)
        // The keyboard stays up. Messages draws its menu over the keyboard
        // with a private keyboard snapshot; the system draws the keyboard
        // (and any input view) above every app window, so the menu stays
        // above it instead.
        if keyboardProgress > 0 {
            overlay.keyboardTop = keyboardDock.guide.layoutFrame.minY
        }
        overlay.onDismissed = { [weak self] in self?.composer.isPlusGlassHidden = false }
        view.addSubview(overlay)
        composer.isPlusGlassHidden = true
        overlay.present()
    }

    /// Opens a photo full screen, as Messages does: it flies out of its
    /// bubble (the outline morphing to the square photo), and Close or a
    /// drag down flies it back into the bubble's rounded, tailed shape.
    func presentPhotoViewer(from imageView: UIImageView) {
        guard let image = imageView.image else { return }
        let cell = sequence(first: imageView as UIView, next: { $0.superview }).lazy.compactMap { $0 as? MessageCell }.first
        let model = cell?.model
        let index = cell?.imageViews.firstIndex(of: imageView) ?? 0
        let tailed = model.map {
            $0.showsTail && index == (cell?.cellLayout?.imageFrames.count ?? 0) - 1 && $0.message.text.isEmpty && $0.message.fileAttachments.isEmpty
        } ?? false
        presentPhoto(image, source: ConversationPhotoSource(view: imageView, side: model?.isOutgoing == false ? .leading : .trailing, tailed: tailed), model: model)
    }

    /// A document's bubble was tapped: a photo sent as a file opens in the
    /// photo viewer; anything else opens in Quick Look.
    func openFile(_ attachment: ConversationAttachment, from fileView: ConversationFileBubbleView, model: MessageRowModel) {
        guard attachment.file?.isImage == true else {
            // Every document of the message opens, to swipe between (Messages).
            let documents = model.message.fileAttachments.filter { $0.file?.isImage != true }
            presentAttachments(documents.isEmpty ? [attachment] : documents, opening: attachment, from: fileView.thumbnailView)
            return
        }
        let tailed = model.showsTail && model.message.text.isEmpty && fileView === fileViews(of: model.rowID).last
        Task { @MainActor [weak self, weak fileView] in
            let image = await ConversationImageLoader.shared.image(for: attachment, pixelWidth: 2400)
            guard let self, let fileView, fileView.window != nil else { return }
            guard let image else {
                self.presentAttachment(attachment, from: fileView.thumbnailView)
                return
            }
            self.presentPhoto(image, source: ConversationPhotoSource(view: fileView, side: model.isOutgoing ? .trailing : .leading, tailed: tailed), model: model)
        }
    }

    private func fileViews(of rowID: String) -> [ConversationFileBubbleView] {
        visibleCell(rowID: rowID)?.fileViews.filter { !$0.isHidden } ?? []
    }

    private func presentPhoto(_ image: UIImage, source: ConversationPhotoSource, model: MessageRowModel?) {
        guard presentedViewController == nil else { return }
        dismissPhotoDrawer()
        view.endEditing(true)
        let viewer = ConversationPhotoViewerController(image: image)
        if let model, model.message.seq != nil {
            let message = model.message
            viewer.onReply = { [weak self] in self?.enterReplyMode(for: message) }
            viewer.onTapback = { [weak self] in
                guard let self, let cell = self.visibleCell(rowID: model.rowID), let current = cell.model else { return }
                self.presentActions(for: current, cell: cell, mode: .tapbacks)
            }
        }
        if viewer.usesSystemZoom, #available(iOS 18.0, *) {
            // iOS 27 Messages: UIKit's zoom transition, the whole viewer a
            // rounded card that grows out of the bubble, drags down and
            // shrinks back into it, the bubble's photo aligned to the photo.
            let options = UIViewController.Transition.ZoomOptions()
            options.interactiveDismissShouldBegin = { [weak viewer] _ in
                MainActor.assumeIsolated { viewer?.allowsInteractiveDismiss ?? true }
            }
            options.alignmentRectProvider = { [weak viewer] _ in
                MainActor.assumeIsolated { viewer?.photoAlignmentRect }
            }
            let sourceView = source.view
            viewer.preferredTransition = .zoom(options: options) { [weak sourceView] _ in sourceView }
            viewer.modalPresentationStyle = .fullScreen
            photoTransition = nil
            present(viewer, animated: true)
            return
        }
        let transition = ConversationPhotoZoomTransition(source: source)
        photoTransition = transition
        viewer.hidesSource = { [weak sourceView = source.view] hidden in sourceView?.alpha = hidden ? 0 : 1 }
        viewer.modalPresentationStyle = .overFullScreen
        viewer.transitioningDelegate = transition
        present(viewer, animated: true)
    }

    private func visibleCell(rowID: String) -> MessageCell? {
        collectionView.visibleCells.lazy.compactMap { $0 as? MessageCell }.first { $0.model?.rowID == rowID }
    }

    /// Quick Look for any attachment: photos open titled "Photo", documents
    /// by their file name. `sourceView` is the bubble it zooms from.
    func presentAttachment(_ attachment: ConversationAttachment, from sourceView: UIView) {
        presentAttachments([attachment], opening: attachment, from: sourceView)
    }

    /// Quick Look for several attachments, opened at `opening` (it zooms from
    /// `sourceView`), the rest a swipe away.
    func presentAttachments(_ attachments: [ConversationAttachment], opening: ConversationAttachment, from sourceView: UIView) {
        guard quickLookPresenter == nil else { return }
        dismissPhotoDrawer()
        let photoTitle = String(localized: "conversation.quote.photo", defaultValue: "Photo", bundle: .module)
        let placeholder = ConversationQuickLookPresenter(item: ConversationQuickLookItem(url: URL(fileURLWithPath: "/"), title: photoTitle), sourceView: nil)
        quickLookPresenter = placeholder
        Task { @MainActor [weak self, weak sourceView] in
            // The tapped one first: nothing opens without it, and the rest load together.
            guard let url = await ConversationImageLoader.shared.fileURL(for: opening) else {
                self?.quickLookPresenter = nil
                return
            }
            let others = await withTaskGroup(of: (String, URL?).self) { group in
                for attachment in attachments where attachment.id != opening.id {
                    group.addTask { (attachment.id, await ConversationImageLoader.shared.fileURL(for: attachment)) }
                }
                var urls: [String: URL] = [:]
                for await (id, url) in group { if let url { urls[id] = url } }
                return urls
            }
            var items: [ConversationQuickLookItem] = []
            var index = 0
            for attachment in attachments {
                let title = attachment.file?.name ?? photoTitle
                if attachment.id == opening.id {
                    index = items.count
                    items.append(ConversationQuickLookItem(url: url, title: title))
                } else if let other = others[attachment.id] {
                    items.append(ConversationQuickLookItem(url: other, title: title))
                }
            }
            if !attachments.contains(where: { $0.id == opening.id }) { items = [ConversationQuickLookItem(url: url, title: opening.file?.name ?? photoTitle)] }
            self?.presentQuickLook(items, index: index, from: sourceView)
        }
    }

    /// A queued attachment was tapped in the composer: every queued
    /// attachment opens in Quick Look, at the tapped one.
    func openComposerAttachment(_ id: UUID, from sourceView: UIView) {
        guard quickLookPresenter == nil else { return }
        let queued = composer.attachments
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return }
        let photoTitle = String(localized: "conversation.quote.photo", defaultValue: "Photo", bundle: .module)
        let placeholder = ConversationQuickLookPresenter(item: ConversationQuickLookItem(url: URL(fileURLWithPath: "/"), title: photoTitle), sourceView: nil)
        quickLookPresenter = placeholder
        Task { @MainActor [weak self, weak sourceView] in
            let sources = queued.map(ComposerAttachmentFile.init)
            let files = await Task.detached(priority: .userInitiated) { sources.map { $0.write() } }.value
            var items: [ConversationQuickLookItem] = []
            var opening = 0
            for (offset, file) in files.enumerated() {
                guard let file else { continue }
                if offset == index { opening = items.count }
                items.append(ConversationQuickLookItem(url: file, title: queued[offset].file?.info.name ?? photoTitle))
            }
            self?.presentQuickLook(items, index: opening, from: sourceView)
        }
    }

    private func presentQuickLook(_ items: [ConversationQuickLookItem], index: Int, from sourceView: UIView?) {
        guard !items.isEmpty, let sourceView, sourceView.window != nil else {
            quickLookPresenter = nil
            return
        }
        view.endEditing(true)
        let presenter = ConversationQuickLookPresenter(items: items, index: index, sourceView: sourceView)
        presenter.onDismiss = { [weak self] in self?.quickLookPresenter = nil }
        quickLookPresenter = presenter
        present(presenter.makeController(), animated: true)
    }

    func presentPhotoDrawer() {
        guard photoDrawer == nil, presentedViewController == nil else { return }
        view.endEditing(true)
        let height = PhotoDrawerGeometry.height(keyboardHeight: dockedKeyboardHeight)
        let drawer = ConversationPhotoSheetController(sheetHeight: height)
        drawer.onSelection = { [weak self] ids in self?.photoSelectionChanged(ids) }
        // Removing a preview from the card deselects its photo in the drawer.
        composer.onRemoveAttachment = { [weak self] attachmentID in
            guard let self, let assetID = self.pickedAssets.first(where: { $0.value == attachmentID })?.key else { return }
            self.pickedAssets[assetID] = nil
            self.photoDrawer?.deselect(assetID: assetID)
        }
        drawer.onDismiss = { [weak self, weak drawer] in
            guard let self, let drawer, self.photoDrawer === drawer else { return }
            self.photoDrawerDidClose(animated: false)
        }
        photoDrawer = drawer
        // The composer rides the sheet's top (its field `fieldGap` above it)
        // at the keyboard detent and while the sheet is dragged down, and
        // holds there while the sheet rises over it to the large detent.
        let link = CADisplayLink(target: PhotoSheetTracker(self), selector: #selector(PhotoSheetTracker.tick))
        link.add(to: .main, forMode: .common)
        photoSheetLink = link
        animateAlongsideKeyboard {
            self.composer.sideInset = self.composer.keyboardSideInset
            self.composer.layoutIfNeeded()
        }
        present(drawer, animated: true)
    }

    /// The composer on the sheet's top, read from the sheet's on-screen
    /// (presentation) frame each display frame.
    func followPhotoSheet() {
        guard let drawer = photoDrawer, let sheetView = drawer.presentationController?.presentedView,
              let container = drawer.presentationController?.containerView else { return }
        let layer = sheetView.layer.presentation() ?? sheetView.layer
        let top = view.convert(layer.frame, from: container).minY
        let height = PhotoDrawerGeometry.height(keyboardHeight: dockedKeyboardHeight)
        let restTop = view.bounds.height - PhotoDrawerGeometry.inset - height
        let safeBottom = view.bounds.height - view.safeAreaInsets.bottom
        let bottom = PhotoDrawerGeometry.composerBottom(sheetTop: top, restingSheetTop: restTop, safeBottom: safeBottom)
        guard composerBottomConstraint?.constant != bottom else { return }
        composerBottomConstraintConstant(bottom)
        view.layoutIfNeeded()
    }

    func dismissPhotoDrawer() {
        guard let drawer = photoDrawer else { return }
        photoDrawerDidClose(animated: true)
        drawer.dismiss(animated: true)
    }

    /// The sheet is gone or going: the composer returns to its base line,
    /// usually inside the keyboard's show animation (see viewDidLoad).
    private func photoDrawerDidClose(animated: Bool) {
        photoDrawer = nil
        pickedAssets = [:]
        photoSheetLink?.invalidate()
        photoSheetLink = nil
        let reset = {
            self.composer.sideInset = ConversationTheme.composerSideInset
            self.composer.layoutIfNeeded()
            self.composerBottomConstraintConstant(-4)
            self.view.layoutIfNeeded()
        }
        if animated { animateAlongsideKeyboard(reset) } else { reset() }
    }

    private func photoSelectionChanged(_ ids: [String]) {
        for (id, attachmentID) in pickedAssets where !ids.contains(id) {
            pickedAssets[id] = nil
            composer.removeAttachment(id: attachmentID)
        }
        let added = ids.filter { pickedAssets[$0] == nil }
        guard !added.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: added, options: nil)
        assets.enumerateObjects { asset, _, _ in self.loadPickedPhoto(asset) }
    }

    private func loadPickedPhoto(_ asset: PHAsset) {
        let id = asset.localIdentifier
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { [weak self] data, uti, _, _ in
            Task { @MainActor in
                // The photo loads asynchronously; drop it if it was deselected
                // or already cleared by a send while it loaded.
                guard let self, let data, let image = UIImage(data: data),
                      self.photoDrawer?.isSelected(assetID: id) == true, self.pickedAssets[id] == nil else { return }
                let isPNG = uti == UTType.png.identifier
                let attachment = ComposerAttachment(image: image, data: data, mimeType: isPNG ? "image/png" : "image/jpeg")
                self.pickedAssets[id] = attachment.id
                self.composer.addAttachment(attachment)
            }
        }
    }

    private func presentCamera() {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = cameraDelegate
        present(picker, animated: true)
    }

    /// UIKit's keyboard animation on iOS 26 and 27: a critically damped
    /// spring with stiffness 555 and damping 47.1 (response 2π/√555 =
    /// 0.2667 s), read from the animations UIKit adds for a keyboard
    /// notification (curve 7, 0.383 s). Inside a keyboard notification the
    /// block inherits UIKit's own animation instead.
    func animateAlongsideKeyboard(_ animations: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        UIView.animate(
            springDuration: 0.2667, bounce: 0, options: [.beginFromCurrentState],
            animations: animations, completion: completion
        )
    }

    /// Files: the system document picker, for any file to attach.
    private func presentFilePicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .package], asCopy: true)
        picker.delegate = cameraDelegate
        present(picker, animated: true)
    }

    private func composerBottomConstraintConstant(_ value: CGFloat) {
        composerBottomConstraint?.constant = value
    }
}

/// Bridges camera and file pickers into the composer.
@MainActor
final class ConversationMediaDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate {
    weak var controller: ConversationViewController?

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.92) else { return }
        controller?.composer.addAttachment(ComposerAttachment(image: image, data: data, mimeType: "image/jpeg"))
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls {
            Task { @MainActor [weak self] in
                guard let traits = self?.controller?.traitCollection,
                      let attachment = await Self.composerAttachment(for: url, traits: traits) else { return }
                self?.controller?.composer.addAttachment(attachment)
            }
        }
    }

    /// A picked file: a photo becomes a photo attachment (as from Photos);
    /// anything else (or an image UIKit cannot decode) is sent as a file.
    static func composerAttachment(for url: URL, traits: UITraitCollection) async -> ComposerAttachment? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let file = ConversationPendingFile(data: data, name: url.lastPathComponent)
        if file.info.isImage, let image = UIImage(data: data) {
            return ComposerAttachment(image: image, data: data, mimeType: file.info.mimeType)
        }
        let chip = await ComposerFileChip.render(file: file.info, url: url, traits: traits)
        return ComposerAttachment(file: file, chip: chip)
    }
}

/// Breaks the display link's strong reference to the conversation.
@MainActor
final class PhotoSheetTracker: NSObject {
    weak var controller: ConversationViewController?
    init(_ controller: ConversationViewController) { self.controller = controller }
    @objc func tick() { controller?.followPhotoSheet() }
}
#endif
