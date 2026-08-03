import CmuxAgentChat

#if canImport(UIKit)
import UIKit

/// Native outgoing attachment bubble with a lifecycle-bound thumbnail task.
@MainActor
public final class ChatAttachmentBubbleView: UIControl {
    private let attachment: ChatAttachment
    private let artifactLoader: ChatArtifactLoader
    private let onOpenArtifact: (@MainActor (String) -> Void)?
    private let thumbnailView = UIImageView()
    private var thumbnailTask: Task<Void, Never>?

    public init(
        attachment: ChatAttachment,
        groupPosition _: ChatGroupPosition,
        showsTimestamp: Bool,
        timestamp: Date,
        artifactLoader: ChatArtifactLoader = .unsupported(),
        onOpenArtifact: (@MainActor (String) -> Void)? = nil
    ) {
        self.attachment = attachment
        self.artifactLoader = artifactLoader
        self.onOpenArtifact = onOpenArtifact
        super.init(frame: .zero)

        let bubble = makeBubble()
        let column = UIStackView(arrangedSubviews: [bubble])
        column.axis = .vertical
        column.alignment = .trailing
        column.spacing = 3
        if showsTimestamp {
            let timestampLabel = UILabel()
            timestampLabel.text = timestamp.formatted(.dateTime.hour().minute())
            timestampLabel.font = .preferredFont(forTextStyle: .caption2)
            timestampLabel.textColor = .tertiaryLabel
            column.addArrangedSubview(timestampLabel)
        }
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 64),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.78),
        ])

        if attachment.hostPath?.isEmpty == false, onOpenArtifact != nil {
            addTarget(self, action: #selector(openArtifact), for: .primaryActionTriggered)
            accessibilityTraits.insert(.button)
        }
        isAccessibilityElement = true
        accessibilityLabel = displayName
        if let path = attachment.hostPath, !path.isEmpty {
            accessibilityValue = path
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            thumbnailTask?.cancel()
            thumbnailTask = nil
        } else {
            loadThumbnailIfNeeded()
        }
    }

    @objc private func openArtifact() {
        guard let path = attachment.hostPath, !path.isEmpty else { return }
        onOpenArtifact?(path)
    }

    private func makeBubble() -> UIView {
        let content = UIStackView()
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 8

        if attachment.media == .image, attachment.hostPath?.isEmpty == false {
            thumbnailView.image = UIImage(systemName: "photo")
            thumbnailView.tintColor = UIColor.white.withAlphaComponent(0.82)
            thumbnailView.backgroundColor = UIColor.white.withAlphaComponent(0.16)
            thumbnailView.contentMode = .center
            thumbnailView.layer.cornerRadius = 6
            thumbnailView.layer.masksToBounds = true
            thumbnailView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                thumbnailView.widthAnchor.constraint(equalToConstant: 48),
                thumbnailView.heightAnchor.constraint(equalToConstant: 48),
            ])
            content.addArrangedSubview(thumbnailView)
        }

        let labels = UIStackView()
        labels.axis = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let nameRow = UIStackView()
        nameRow.axis = .horizontal
        nameRow.alignment = .center
        nameRow.spacing = 6
        let icon = UIImageView(image: UIImage(systemName: attachment.media == .image ? "photo" : "doc"))
        icon.tintColor = .white
        let name = UILabel()
        name.text = displayName
        name.font = .preferredFont(forTextStyle: .caption1)
        name.textColor = .white
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingMiddle
        nameRow.addArrangedSubview(icon)
        nameRow.addArrangedSubview(name)
        labels.addArrangedSubview(nameRow)

        if let path = attachment.hostPath, !path.isEmpty {
            let pathLabel = UILabel()
            pathLabel.text = path
            pathLabel.font = .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                weight: .regular
            )
            pathLabel.textColor = UIColor.white.withAlphaComponent(0.7)
            pathLabel.numberOfLines = 1
            pathLabel.lineBreakMode = .byTruncatingMiddle
            labels.addArrangedSubview(pathLabel)
        }
        content.addArrangedSubview(labels)

        let bubble = UIView()
        bubble.backgroundColor = .systemBlue
        bubble.layer.cornerRadius = 18
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
        ])
        return bubble
    }

    private var displayName: String {
        if let name = attachment.displayName, !name.isEmpty {
            return name
        }
        switch attachment.media {
        case .image:
            return String(localized: "chat.attachment.image", defaultValue: "Image", bundle: .module)
        case .file:
            return String(localized: "chat.attachment.file", defaultValue: "File", bundle: .module)
        }
    }

    private func loadThumbnailIfNeeded() {
        guard thumbnailTask == nil,
              attachment.media == .image,
              let path = attachment.hostPath,
              !path.isEmpty,
              artifactLoader.supportsArtifacts
        else { return }
        thumbnailTask = Task { [weak self, artifactLoader] in
            do {
                let thumbnail = try await artifactLoader.thumbnail(path: path, maxDimension: 256)
                try Task.checkCancellation()
                guard let self, let image = UIImage(data: thumbnail.data) else { return }
                self.thumbnailView.image = image
                self.thumbnailView.contentMode = .scaleAspectFill
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }
}
#endif
