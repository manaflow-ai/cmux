#if canImport(UIKit)
import CmuxConversationCore
import Photos
import UIKit
import UniformTypeIdentifiers

/// The "+" apps menu: a glass panel anchored above the + button over a
/// blurred, dimmed transcript.
final class AppsMenuOverlay: UIView {
    struct Item {
        var title: String
        var symbol: String
        var color: UIColor
        /// Drawn instead of `symbol` on `color` (Send Later's dashed clock).
        var customIcon: UIImage? = nil
        var handler: () -> Void
    }

    private let backdrop = UIVisualEffectView(effect: nil)
    private let panel = makeGlassView(cornerRadius: 36)
    private let stack = UIStackView()
    private let anchor: CGRect
    private var blurAnimator: UIViewPropertyAnimator?

    init(frame: CGRect, anchor: CGRect, items: [Item]) {
        self.anchor = anchor
        super.init(frame: frame)
        accessibilityIdentifier = "conversation.appsMenu"
        accessibilityViewIsModal = true
        backdrop.frame = bounds
        addSubview(backdrop)
        addSubview(panel)
        stack.axis = .vertical
        panel.contentView.addSubview(stack)
        for item in items {
            let row = UIButton(type: .custom)
            let icon = UIImageView(image: item.customIcon ?? UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))
            icon.tintColor = .white
            icon.contentMode = .center
            icon.backgroundColor = item.color
            icon.layer.cornerRadius = 16
            icon.frame = CGRect(x: 26, y: 15.5, width: 32, height: 32)
            row.addSubview(icon)
            let label = UILabel(frame: CGRect(x: 80, y: 0, width: 190, height: 63))
            label.text = item.title
            label.font = .systemFont(ofSize: 20)
            label.textColor = .label
            row.addSubview(label)
            row.heightAnchor.constraint(equalToConstant: 63).isActive = true
            row.accessibilityLabel = item.title
            row.accessibilityIdentifier = "conversation.apps.\(item.symbol)"
            row.addAction(UIAction { [weak self] _ in self?.dismiss(then: item.handler) }, for: .touchUpInside)
            stack.addArrangedSubview(row)
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        let height = CGFloat(stack.arrangedSubviews.count) * 63 + 32
        let width: CGFloat = 284
        // Anchored to the + button's corner; covers the composer like Messages.
        panel.frame = CGRect(x: 16, y: anchor.maxY - height + 4, width: width, height: height)
        stack.frame = panel.bounds.insetBy(dx: 0, dy: 16)
        // A partial blur, as in Messages: the transcript fades but stays legible.
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) {
            self.backdrop.effect = UIBlurEffect(style: .systemThinMaterial)
        }
        animator.pausesOnCompletion = true
        animator.fractionComplete = 0.22
        blurAnimator = animator
        backdrop.alpha = 0
        panel.alpha = 0
        panel.transform = UIAccessibility.isReduceMotionEnabled ? .identity : CGAffineTransform(translationX: -width * 0.25, y: height * 0.3).scaledBy(x: 0.5, y: 0.5)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0) {
            self.backdrop.alpha = 1
            self.panel.alpha = 1
            self.panel.transform = .identity
        }
    }

    func dismiss(then completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.backdrop.alpha = 0
            self.panel.alpha = 0
            self.panel.transform = UIAccessibility.isReduceMotionEnabled ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
        } completion: { _ in
            self.blurAnimator?.stopAnimation(true)
            self.blurAnimator = nil
            self.removeFromSuperview()
            completion?()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss()
        return true
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        if !panel.frame.contains(tap.location(in: self)) { dismiss() }
    }
}

extension ConversationViewController {
    func presentAppsMenu() {
        dismissPhotoDrawer()
        view.endEditing(true)
        var items: [AppsMenuOverlay.Item] = []
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            items.append(.init(title: String(localized: "conversation.apps.camera", defaultValue: "Camera", bundle: .module), symbol: "camera.fill", color: .systemGray) { [weak self] in
                self?.presentCamera()
            })
        }
        items.append(.init(title: String(localized: "conversation.apps.photos", defaultValue: "Photos", bundle: .module), symbol: "photo.on.rectangle", color: .systemBlue) { [weak self] in
            self?.presentPhotoDrawer()
        })
        items.append(.init(title: String(localized: "conversation.apps.files", defaultValue: "Files", bundle: .module), symbol: "folder.fill", color: .systemIndigo) { [weak self] in
            self?.presentFilePicker()
        })
        items.append(.init(title: String(localized: "conversation.apps.audio", defaultValue: "Audio", bundle: .module), symbol: "waveform", color: UIColor(red: 1, green: 0.43, blue: 0.32, alpha: 1)) { [weak self] in
            self?.audioComposer.start()
        })
        items.append(pollsAppsMenuItem())
        items.append(sendLaterMenuItem())
        let anchor = composer.plusButton.convert(composer.plusButton.bounds, to: view)
        let overlay = AppsMenuOverlay(frame: view.bounds, anchor: anchor, items: items)
        view.addSubview(overlay)
        overlay.present()
    }

    /// Opens a photo full screen. On iOS 18+ it zooms out of its bubble and
    /// back, and swiping down dismisses interactively, as in Messages.
    func presentPhotoViewer(from imageView: UIImageView) {
        guard let image = imageView.image else { return }
        dismissPhotoDrawer()
        view.endEditing(true)
        let viewer = ConversationPhotoViewerController(image: image)
        viewer.modalPresentationStyle = .fullScreen
        if #available(iOS 18.0, *) {
            let options = UIViewController.Transition.ZoomOptions()
            options.interactiveDismissShouldBegin = { [weak viewer] _ in viewer?.allowsInteractiveDismiss ?? true }
            options.alignmentRectProvider = { [weak viewer] context in
                guard let viewer else { return .zero }
                return viewer.photoView.convert(viewer.photoView.bounds, to: context.zoomedViewController.view)
            }
            viewer.preferredTransition = .zoom(options: options) { [weak imageView] _ in imageView }
        }
        present(viewer, animated: true)
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

    private func presentFilePicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
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
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { continue }
            self.controller?.composer.addAttachment(ComposerAttachment(image: image, data: data, mimeType: url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"))
        }
    }
}
#endif
