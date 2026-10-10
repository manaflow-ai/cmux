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
    private let panel = makeGlassView(cornerRadius: ConversationTheme.plusButtonSize / 2)
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
        let label = UILabel(frame: CGRect(x: labelX, y: (G.rowHeight - G.labelHeight) / 2, width: G.maximumWidth - labelX - 16, height: G.labelHeight))
        label.text = item.title
        label.font = .systemFont(ofSize: G.labelFontSize)
        // `sendMenuListItemTextColor`, as measured on screen.
        let lightWhite = G.labelWhite(iOS27: SendMenuIcons.isIOS27)
        label.textColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.7) : UIColor(white: lightWhite, alpha: 1) }
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
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
            overlay.keyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
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
            presentAttachment(attachment, from: fileView.thumbnailView)
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
        let transition = ConversationPhotoZoomTransition(source: source)
        photoTransition = transition
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
        guard quickLookPresenter == nil else { return }
        dismissPhotoDrawer()
        let title = attachment.file?.name ?? String(localized: "conversation.quote.photo", defaultValue: "Photo", bundle: .module)
        let placeholder = ConversationQuickLookPresenter(item: ConversationQuickLookItem(url: URL(fileURLWithPath: "/"), title: title), sourceView: nil)
        quickLookPresenter = placeholder
        Task { @MainActor [weak self, weak sourceView] in
            let url = await ConversationImageLoader.shared.fileURL(for: attachment)
            guard let self else { return }
            guard let url, let sourceView, sourceView.window != nil else {
                self.quickLookPresenter = nil
                return
            }
            self.view.endEditing(true)
            let presenter = ConversationQuickLookPresenter(item: ConversationQuickLookItem(url: url, title: title), sourceView: sourceView)
            presenter.onDismiss = { [weak self] in self?.quickLookPresenter = nil }
            self.quickLookPresenter = presenter
            self.present(presenter.makeController(), animated: true)
        }
    }

    func presentPhotoDrawer() {
        guard photoDrawer == nil else { return }
        view.endEditing(true)
        let drawer = ConversationPhotoGridView()
        drawer.onToggle = { [weak self] asset, selected in
            self?.photoSelectionChanged(asset: asset, selected: selected)
        }
        // Removing a preview from the card deselects its photo in the drawer.
        composer.onRemoveAttachment = { [weak self] attachmentID in
            guard let self, let assetID = self.pickedAssets.first(where: { $0.value == attachmentID })?.key else { return }
            self.pickedAssets[assetID] = nil
            self.photoDrawer?.deselect(assetID: assetID)
        }
        // Measured on iOS 26 Messages (iPhone 17 Pro): a card inset 8 pt from
        // the sides and bottom, as tall as the keyboard area (336 pt plus the
        // home-indicator inset), with the field 24 pt above its top edge.
        let inset: CGFloat = 8
        let height: CGFloat = 336 + view.safeAreaInsets.bottom
        let top = view.bounds.height - inset - height
        drawer.frame = CGRect(x: inset, y: view.bounds.height, width: view.bounds.width - 2 * inset, height: height)
        view.addSubview(drawer)
        photoDrawer = drawer
        // The composer's field sits 4 pt above its container's bottom.
        let composerBottom = top - 20 - (view.bounds.height - view.safeAreaInsets.bottom)
        // On the keyboard's own curve: the keyboard leaving and the drawer
        // arriving move the composer as one motion, never down then up.
        animateAlongsideKeyboard {
            drawer.frame.origin.y = top
            self.composer.sideInset = 16
            self.composer.layoutIfNeeded()
            self.composerBottomConstraintConstant(composerBottom)
            self.view.layoutIfNeeded()
        }
    }

    func dismissPhotoDrawer() {
        guard let drawer = photoDrawer else { return }
        photoDrawer = nil
        pickedAssets = [:]
        // Usually inside the keyboard's show animation (see viewDidLoad),
        // which this matches, so the composer rides up with the keyboard.
        animateAlongsideKeyboard {
            drawer.frame.origin.y = self.view.bounds.height
            self.composer.sideInset = ConversationTheme.composerSideInset
            self.composer.layoutIfNeeded()
            self.composerBottomConstraintConstant(-4)
            self.view.layoutIfNeeded()
        } completion: { _ in
            drawer.removeFromSuperview()
        }
    }

    private func photoSelectionChanged(asset: PHAsset, selected: Bool) {
        let id = asset.localIdentifier
        guard selected else {
            if let attachmentID = pickedAssets.removeValue(forKey: id) { composer.removeAttachment(id: attachmentID) }
            return
        }
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
#endif
