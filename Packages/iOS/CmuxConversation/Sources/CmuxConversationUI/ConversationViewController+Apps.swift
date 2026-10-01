#if canImport(UIKit)
import CmuxConversationCore
@preconcurrency import PhotosUI
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
    private let panel = makeGlassView(cornerRadius: 28)
    private let stack = UIStackView()
    private let anchor: CGRect

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
            icon.layer.cornerRadius = 14
            icon.frame = CGRect(x: 20, y: 10, width: 28, height: 28)
            row.addSubview(icon)
            let label = UILabel(frame: CGRect(x: 62, y: 0, width: 180, height: 48))
            label.text = item.title
            label.font = .systemFont(ofSize: 17)
            label.textColor = .label
            row.addSubview(label)
            row.heightAnchor.constraint(equalToConstant: 48).isActive = true
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
        let height = CGFloat(stack.arrangedSubviews.count) * 48 + 16
        let width: CGFloat = 230
        panel.frame = CGRect(x: anchor.minX, y: anchor.minY - 10 - height, width: width, height: height)
        stack.frame = panel.bounds.insetBy(dx: 0, dy: 8)
        panel.alpha = 0
        panel.transform = CGAffineTransform(translationX: -width * 0.25, y: height * 0.3).scaledBy(x: 0.5, y: 0.5)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0) {
            self.backdrop.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            self.panel.alpha = 1
            self.panel.transform = .identity
        }
    }

    func dismiss(then completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.backdrop.effect = nil
            self.panel.alpha = 0
            self.panel.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        } completion: { _ in
            self.removeFromSuperview()
            completion?()
        }
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        if !panel.frame.contains(tap.location(in: self)) { dismiss() }
    }
}

/// Inline photo picker occupying the keyboard area, like Messages' Photos app.
final class ConversationPhotoDrawer: UIView {
    let picker: PHPickerViewController

    init(picker: PHPickerViewController) {
        self.picker = picker
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        accessibilityIdentifier = "conversation.photoDrawer"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

extension ConversationViewController: PHPickerViewControllerDelegate {
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
        let anchor = composer.convert(composer.plusButton.superview?.frame ?? .zero, to: view)
        let overlay = AppsMenuOverlay(frame: view.bounds, anchor: anchor, items: items)
        view.addSubview(overlay)
        overlay.present()
    }

    func presentPhotoDrawer() {
        guard photoDrawer == nil else { return }
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 10
        configuration.selection = .continuousAndOrdered
        configuration.mode = .compact
        configuration.disabledCapabilities = [.search, .collectionNavigation, .stagingArea, .selectionActions]
        configuration.edgesWithoutContentMargins = .all
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        let drawer = ConversationPhotoDrawer(picker: picker)
        let height: CGFloat = 330 + view.safeAreaInsets.bottom
        drawer.frame = CGRect(x: 0, y: view.bounds.height, width: view.bounds.width, height: height)
        addChild(picker)
        drawer.addSubview(picker.view)
        picker.view.frame = drawer.bounds
        picker.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(drawer)
        picker.didMove(toParent: self)
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
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            drawer.frame.origin.y = self.view.bounds.height
            self.composerBottomConstraintConstant(-4)
            self.view.layoutIfNeeded()
        } completion: { _ in
            drawer.picker.willMove(toParent: nil)
            drawer.picker.view.removeFromSuperview()
            drawer.picker.removeFromParent()
            drawer.removeFromSuperview()
        }
    }

    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        // Continuous selection reports the full ordered set each time.
        let existing = Set(pickedAssetIDs)
        let current = results.compactMap(\.assetIdentifier)
        pickedAssetIDs = current
        for result in results {
            if let id = result.assetIdentifier, existing.contains(id) { continue }
            loadAttachment(from: result.itemProvider)
        }
        if results.isEmpty { dismissPhotoDrawer() }
    }

    func loadAttachment(from provider: NSItemProvider) {
        let type = provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier) ? UTType.jpeg : UTType.image
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { [weak self] data, _ in
            guard let data, let image = UIImage(data: data) else { return }
            let mime = type == .jpeg ? "image/jpeg" : (UTType(filenameExtension: "png") == type ? "image/png" : "image/jpeg")
            let payload = type == .jpeg ? data : (image.jpegData(compressionQuality: 0.92) ?? data)
            Task { @MainActor in
                self?.composer.addAttachment(ComposerAttachment(image: image, data: payload, mimeType: mime))
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
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
