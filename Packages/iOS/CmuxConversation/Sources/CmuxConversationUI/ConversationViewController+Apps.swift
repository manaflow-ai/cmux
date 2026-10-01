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
        backdrop.frame = bounds
        addSubview(backdrop)
        addSubview(panel)
        stack.axis = .vertical
        panel.contentView.addSubview(stack)
        for item in items {
            let row = UIButton(type: .custom)
            let icon = UIImageView(image: UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))
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
        panel.transform = CGAffineTransform(translationX: -width * 0.25, y: height * 0.3).scaledBy(x: 0.5, y: 0.5)
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
            self.panel.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        } completion: { _ in
            self.blurAnimator?.stopAnimation(true)
            self.blurAnimator = nil
            self.removeFromSuperview()
            completion?()
        }
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
        let anchor = composer.plusButton.convert(composer.plusButton.bounds, to: view)
        let overlay = AppsMenuOverlay(frame: view.bounds, anchor: anchor, items: items)
        view.addSubview(overlay)
        overlay.present()
    }

    func presentPhotoDrawer() {
        guard photoDrawer == nil else { return }
        view.endEditing(true)
        let drawer = ConversationPhotoGridView()
        drawer.onToggle = { [weak self] asset, selected in
            self?.photoSelectionChanged(asset: asset, selected: selected)
        }
        let height: CGFloat = 330 + view.safeAreaInsets.bottom
        drawer.frame = CGRect(x: 6, y: view.bounds.height, width: view.bounds.width - 12, height: height - 6)
        view.addSubview(drawer)
        photoDrawer = drawer
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            drawer.frame.origin.y = self.view.bounds.height - height
            self.composerBottomConstraintConstant(-(height - self.view.safeAreaInsets.bottom) - 4)
            self.view.layoutIfNeeded()
        }
    }

    func dismissPhotoDrawer() {
        guard let drawer = photoDrawer else { return }
        photoDrawer = nil
        pickedAssets = [:]
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            drawer.frame.origin.y = self.view.bounds.height
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
                guard let self, let data, let image = UIImage(data: data) else { return }
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

/// Conversation details: avatar, name and participants.
final class ConversationInfoViewController: UITableViewController {
    private let info: ConversationInfo
    private let meID: String?

    init(info: ConversationInfo, meID: String?) {
        self.info = info
        self.meID = meID
        super.init(style: .insetGrouped)
        title = info.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if navigationController?.viewControllers.first === self {
            navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        }
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 150))
        let avatar = ConversationAvatarView(frame: CGRect(x: 0, y: 16, width: 90, height: 90))
        avatar.configure(initials: info.kind == .group ? String(info.title.prefix(2)).uppercased() : (info.participants.first { $0.id != meID }?.initials ?? ""), colorHex: nil)
        avatar.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
        header.addSubview(avatar)
        let name = UILabel(frame: CGRect(x: 0, y: 114, width: 0, height: 28))
        name.text = info.title
        name.font = .systemFont(ofSize: 24, weight: .bold)
        name.textAlignment = .center
        name.autoresizingMask = [.flexibleWidth]
        header.addSubview(name)
        tableView.tableHeaderView = header
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "p")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let header = tableView.tableHeaderView, let avatar = header.subviews.first {
            avatar.center.x = header.bounds.midX
            header.subviews.last?.frame.size.width = header.bounds.width
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        info.participants.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        String(format: String(localized: "conversation.info.members", defaultValue: "%d Members", bundle: .module), info.participants.count)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "p", for: indexPath)
        let participant = info.participants[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = participant.isMe ? String(localized: "conversation.reaction.you", defaultValue: "You", bundle: .module) : participant.name
        cell.contentConfiguration = content
        return cell
    }
}
#endif
