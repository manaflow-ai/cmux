import UIKit

/// The long look's reply bar, docked at the bottom as Messages' notification
/// reply is: "+" (Photos, Files), a glass capsule with the text and the
/// picked attachments, and the send arrow once there is something to send.
/// The view controller returns it as its `inputAccessoryView`, so it rests at
/// the bottom and rides on the keyboard while typing.
final class ComposerBar: UIView, UITextViewDelegate {
    struct AttachmentKinds: OptionSet {
        let rawValue: Int
        static let photos = AttachmentKinds(rawValue: 1)
        static let files = AttachmentKinds(rawValue: 2)
    }

    struct Attachment: Equatable {
        var name: String
        var title: String
        var thumbnail: UIImage?
    }

    var onSend: (String) -> Void = { _ in }
    var onTextChange: (String) -> Void = { _ in }
    var onPickPhotos: () -> Void = {}
    var onPickFiles: () -> Void = {}
    var onRemove: (String) -> Void = { _ in }

    let textView = UITextView()
    private let placeholder = UILabel()
    private let plusGlass = UIVisualEffectView(effect: UIGlassEffect())
    private let plusButton = UIButton(type: .system)
    private let fieldGlass = UIVisualEffectView(effect: UIGlassEffect())
    private let sendButton = UIButton(type: .system)
    private let shelf = UIScrollView()
    private let shelfStack = UIStackView()
    private var textHeight: NSLayoutConstraint?
    private var shelfHeight: NSLayoutConstraint?
    private(set) var attachments: [Attachment] = []
    /// What "+" offers; none hides it (a question's text is its "Other" answer).
    var attachmentKinds: AttachmentKinds = [.photos, .files] { didSet { updateMenu() } }

    static let maxLines: CGFloat = 5
    static let thumbnailSize: CGFloat = 56

    init(placeholder text: String) {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 52))
        autoresizingMask = .flexibleHeight
        backgroundColor = .clear

        plusButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .large)), for: .normal)
        plusButton.tintColor = .label
        plusButton.showsMenuAsPrimaryAction = true
        updateMenu()
        plusButton.accessibilityIdentifier = "cmux.push.attach"
        for glass in [plusGlass, fieldGlass] {
            glass.layer.cornerRadius = 19
            glass.layer.cornerCurve = .continuous
        }
        plusGlass.contentView.addSubview(plusButton)

        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 9, left: 8, bottom: 9, right: 4)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityIdentifier = "cmux.push.composer"
        textView.accessibilityLabel = text
        placeholder.text = text
        placeholder.font = textView.font
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.isAccessibilityElement = false

        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)), for: .normal)
        sendButton.tintColor = .systemBlue
        sendButton.accessibilityLabel = String(localized: "Send")
        sendButton.accessibilityIdentifier = "cmux.push.send"
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .touchUpInside)

        shelf.showsHorizontalScrollIndicator = false
        shelf.alwaysBounceHorizontal = false
        shelfStack.axis = .horizontal
        shelfStack.spacing = 8
        shelf.addSubview(shelfStack)
        shelf.accessibilityIdentifier = "cmux.push.attachments"

        let column = UIStackView(arrangedSubviews: [shelf, textView])
        column.axis = .vertical
        column.spacing = 0
        fieldGlass.contentView.addSubview(column)
        fieldGlass.contentView.addSubview(placeholder)
        fieldGlass.contentView.addSubview(sendButton)
        let row = UIStackView(arrangedSubviews: [plusGlass, fieldGlass])
        row.axis = .horizontal
        row.alignment = .bottom
        row.spacing = 8
        addSubview(row)

        for view in [row, column, plusButton, placeholder, sendButton, shelfStack] { view.translatesAutoresizingMaskIntoConstraints = false }
        let textHeight = textView.heightAnchor.constraint(equalToConstant: 38)
        let shelfHeight = shelf.heightAnchor.constraint(equalToConstant: 0)
        self.textHeight = textHeight
        self.shelfHeight = shelfHeight
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            plusGlass.widthAnchor.constraint(equalToConstant: 38),
            plusGlass.heightAnchor.constraint(equalToConstant: 38),
            plusButton.leadingAnchor.constraint(equalTo: plusGlass.contentView.leadingAnchor),
            plusButton.trailingAnchor.constraint(equalTo: plusGlass.contentView.trailingAnchor),
            plusButton.topAnchor.constraint(equalTo: plusGlass.contentView.topAnchor),
            plusButton.bottomAnchor.constraint(equalTo: plusGlass.contentView.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: fieldGlass.contentView.leadingAnchor, constant: 4),
            column.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor),
            column.topAnchor.constraint(equalTo: fieldGlass.contentView.topAnchor),
            column.bottomAnchor.constraint(equalTo: fieldGlass.contentView.bottomAnchor),
            textHeight,
            shelfHeight,
            shelfStack.leadingAnchor.constraint(equalTo: shelf.contentLayoutGuide.leadingAnchor, constant: 8),
            shelfStack.trailingAnchor.constraint(equalTo: shelf.contentLayoutGuide.trailingAnchor, constant: -8),
            shelfStack.topAnchor.constraint(equalTo: shelf.contentLayoutGuide.topAnchor, constant: 8),
            shelfStack.bottomAnchor.constraint(equalTo: shelf.contentLayoutGuide.bottomAnchor),
            shelfStack.heightAnchor.constraint(equalTo: shelf.frameLayoutGuide.heightAnchor, constant: -8),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 13),
            placeholder.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: sendButton.leadingAnchor),
            sendButton.trailingAnchor.constraint(equalTo: fieldGlass.contentView.trailingAnchor, constant: -4),
            sendButton.bottomAnchor.constraint(equalTo: fieldGlass.contentView.bottomAnchor, constant: -3),
            sendButton.widthAnchor.constraint(equalToConstant: 32),
            sendButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        updateState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        // An input accessory sizes from this; the bottom safe area joins it when the keyboard is down.
        let field = (textHeight?.constant ?? 38) + (shelfHeight?.constant ?? 0)
        return CGSize(width: UIView.noIntrinsicMetric, height: field + 14)
    }

    private func updateMenu() {
        var items: [UIMenuElement] = []
        if attachmentKinds.contains(.photos) {
            items.append(UIAction(title: String(localized: "Photos"), image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.onPickPhotos() })
        }
        if attachmentKinds.contains(.files) {
            items.append(UIAction(title: String(localized: "Files"), image: UIImage(systemName: "folder")) { [weak self] _ in self?.onPickFiles() })
        }
        plusButton.menu = UIMenu(children: items)
        plusButton.accessibilityLabel = attachmentKinds.contains(.files)
            ? String(localized: "Attach Photos or Files") : String(localized: "Attach Photos")
        plusGlass.isHidden = items.isEmpty
    }

    func setPlaceholder(_ text: String) {
        placeholder.text = text
        textView.accessibilityLabel = text
    }

    func setAttachments(_ items: [Attachment]) {
        attachments = items
        shelfStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items { shelfStack.addArrangedSubview(tile(item)) }
        shelfHeight?.constant = items.isEmpty ? 0 : Self.thumbnailSize + 8
        updateState()
    }

    func clear() {
        textView.text = ""
        setAttachments([])
        textViewDidChange(textView)
    }

    func textViewDidChange(_ textView: UITextView) {
        let line = textView.font?.lineHeight ?? 20
        let insets = textView.textContainerInset.top + textView.textContainerInset.bottom
        let fitted = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        let maximum = ceil(line * Self.maxLines + insets)
        textView.isScrollEnabled = fitted > maximum
        let height = max(38, min(fitted, maximum))
        if textHeight?.constant != height {
            textHeight?.constant = height
            invalidateIntrinsicContentSize()
        }
        updateState()
        onTextChange(textView.text)
    }

    private var canSend: Bool {
        !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private func updateState() {
        placeholder.isHidden = !textView.text.isEmpty
        sendButton.isHidden = !canSend
        invalidateIntrinsicContentSize()
    }

    private func send() {
        guard canSend else { return }
        onSend(textView.text)
    }

    private func tile(_ item: Attachment) -> UIView {
        let size = Self.thumbnailSize
        let tile = UIView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.layer.cornerRadius = 12
        tile.layer.cornerCurve = .continuous
        tile.clipsToBounds = true
        tile.backgroundColor = .tertiarySystemFill
        tile.isAccessibilityElement = true
        tile.accessibilityLabel = item.title
        if let image = item.thumbnail {
            let view = UIImageView(image: image)
            view.contentMode = .scaleAspectFill
            view.frame = CGRect(x: 0, y: 0, width: size, height: size)
            tile.addSubview(view)
        } else {
            let icon = UIImageView(image: UIImage(systemName: "doc.fill"))
            icon.tintColor = .secondaryLabel
            icon.contentMode = .scaleAspectFit
            icon.frame = CGRect(x: size / 2 - 11, y: 8, width: 22, height: 22)
            let label = UILabel(frame: CGRect(x: 4, y: 32, width: size - 8, height: 18))
            label.text = item.title
            label.font = .preferredFont(forTextStyle: .caption2)
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            tile.addSubview(icon)
            tile.addSubview(label)
        }
        let remove = UIButton(type: .system)
        remove.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        remove.tintColor = .white
        remove.layer.shadowOpacity = 0.4
        remove.layer.shadowRadius = 2
        remove.layer.shadowOffset = .zero
        remove.frame = CGRect(x: size - 26, y: 2, width: 24, height: 24)
        remove.accessibilityLabel = String(localized: "Remove \(item.title)")
        remove.addAction(UIAction { [weak self] _ in self?.onRemove(item.name) }, for: .touchUpInside)
        tile.addSubview(remove)
        tile.accessibilityElements = [remove]
        NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: size), tile.heightAnchor.constraint(equalToConstant: size)])
        return tile
    }
}
