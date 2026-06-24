#if canImport(UIKit)
import CmuxAgentChat
import Nuke
import UIKit

/// Visual sender side for bubble alignment.
enum BubbleSide { case mine, theirs }

/// A text bubble for prose and optimistic pending rows.
final class BubbleCell: UICollectionViewCell {
    static let reuseID = "BubbleCell"

    private let bubble = UIView()
    private let label = UILabel()
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Counter-rotate: the collection view is inverted, so each cell must
        // flip back to read right-side-up.
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)

        bubble.layer.cornerRadius = 18
        bubble.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubble)

        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)

        leadingConstraint = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        trailingConstraint = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.78),

            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -9),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 13),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -13),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, side: BubbleSide, pending: Bool) {
        let isCode = text.contains("```")
        label.font = isCode
            ? .monospacedSystemFont(ofSize: 14, weight: .regular)
            : .preferredFont(forTextStyle: .body)
        label.text = isCode ? text.replacingOccurrences(of: "```", with: "") : text

        switch side {
        case .mine:
            bubble.backgroundColor = .tintColor
            label.textColor = .white
            leadingConstraint.isActive = false
            trailingConstraint.isActive = true
        case .theirs:
            bubble.backgroundColor = .secondarySystemBackground
            label.textColor = .label
            trailingConstraint.isActive = false
            leadingConstraint.isActive = true
        }
        contentView.alpha = pending ? 0.55 : 1
    }
}

/// An image bubble, loaded asynchronously through Nuke (off-main decode,
/// memory + disk cache).
final class ImageBubbleCell: UICollectionViewCell {
    static let reuseID = "ImageBubbleCell"

    private let imageView = UIImageView()
    private var imageTask: ImageTask?
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 16
        imageView.backgroundColor = .secondarySystemBackground
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        leadingConstraint = imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        trailingConstraint = imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            imageView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.62),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 0.66),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        imageView.image = nil
    }

    func configure(url: URL?, side: BubbleSide) {
        switch side {
        case .mine:
            leadingConstraint.isActive = false
            trailingConstraint.isActive = true
        case .theirs:
            trailingConstraint.isActive = false
            leadingConstraint.isActive = true
        }
        guard let url else { return }
        imageTask = ImagePipeline.shared.loadImage(with: url) { [weak self] result in
            if case let .success(response) = result {
                self?.imageView.image = response.image
            }
        }
    }
}

/// A centered caption for lifecycle status rows.
final class StatusCell: UICollectionViewCell {
    static let reuseID = "StatusCell"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String) { label.text = text }
}
#endif
