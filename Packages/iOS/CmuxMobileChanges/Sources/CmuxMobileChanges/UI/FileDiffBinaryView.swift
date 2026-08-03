internal import Foundation

#if canImport(UIKit)
internal import UIKit

@MainActor
final class FileDiffBinaryViewController: UIViewController {
    private let fileIndex: Int
    private let file: ChangedFileItem
    private let inlinePreview: (@MainActor @Sendable (Int, FileDiffPreviewRevision) -> UIViewController)?
    private var previewRevision: FileDiffPreviewRevision
    private let contentContainer = UIView()
    private var previewController: UIViewController?

    init(
        fileIndex: Int,
        file: ChangedFileItem,
        previewRevision: FileDiffPreviewRevision,
        inlinePreview: (@MainActor @Sendable (Int, FileDiffPreviewRevision) -> UIViewController)?
    ) {
        self.fileIndex = fileIndex
        self.file = file
        self.previewRevision = previewRevision
        self.inlinePreview = inlinePreview
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let policy = FileDiffPreviewPolicy(kind: file.kind)
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        if policy.allowsRevisionSelection {
            let control = UISegmentedControl(items: [
                String(localized: "changes.binary.before", defaultValue: "Before", bundle: .module),
                String(localized: "changes.binary.after", defaultValue: "After", bundle: .module),
            ])
            control.selectedSegmentIndex = previewRevision == .base ? 0 : 1
            control.accessibilityLabel = String(
                localized: "changes.binary.revision",
                defaultValue: "Revision",
                bundle: .module
            )
            control.addAction(UIAction { [weak self] action in
                guard let self, let control = action.sender as? UISegmentedControl else { return }
                self.previewRevision = control.selectedSegmentIndex == 0 ? .base : .current
                self.renderPreview()
            }, for: .valueChanged)
            let controlContainer = UIView()
            control.translatesAutoresizingMaskIntoConstraints = false
            controlContainer.addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: controlContainer.leadingAnchor, constant: 16),
                control.trailingAnchor.constraint(equalTo: controlContainer.trailingAnchor, constant: -16),
                control.topAnchor.constraint(equalTo: controlContainer.topAnchor, constant: 10),
                control.bottomAnchor.constraint(equalTo: controlContainer.bottomAnchor, constant: -10),
            ])
            stack.addArrangedSubview(controlContainer)
        }
        stack.addArrangedSubview(contentContainer)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        renderPreview()
    }

    private func renderPreview() {
        if let previewController {
            previewController.willMove(toParent: nil)
            previewController.view.removeFromSuperview()
            previewController.removeFromParent()
            self.previewController = nil
        }
        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        if let inlinePreview {
            let controller = inlinePreview(fileIndex, previewRevision)
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
            controller.didMove(toParent: self)
            previewController = controller
        } else {
            installFallback()
        }
    }

    private func installFallback() {
        let documentImage = UIImageView(image: UIImage(systemName: "doc.richtext"))
        documentImage.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .medium)
        documentImage.tintColor = .secondaryLabel

        let filename = UILabel()
        filename.text = file.displayFilename
        filename.font = .preferredFont(forTextStyle: .headline)
        filename.textAlignment = .center
        filename.numberOfLines = 2
        filename.lineBreakMode = .byTruncatingMiddle

        let cardSubviews: [UIView]
        if let byteSize = file.byteSize {
            let size = UILabel()
            size.text = ByteCountFormatter.string(fromByteCount: max(0, byteSize), countStyle: .file)
            size.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
            size.textColor = .secondaryLabel
            cardSubviews = [documentImage, filename, size]
        } else {
            cardSubviews = [documentImage, filename]
        }
        let card = UIStackView(arrangedSubviews: cardSubviews)
        card.axis = .vertical
        card.alignment = .center
        card.spacing = 14
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
        card.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.08)
        card.layer.cornerRadius = 18

        let preview = UIView()
        preview.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.08)
        preview.layer.cornerRadius = 18
        let previewImage = UIImageView(image: UIImage(systemName: "photo.on.rectangle.angled"))
        previewImage.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        previewImage.tintColor = .secondaryLabel
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(previewImage)
        NSLayoutConstraint.activate([
            previewImage.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            previewImage.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])

        let stack = UIStackView(arrangedSubviews: [card, preview])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }
}
#endif
