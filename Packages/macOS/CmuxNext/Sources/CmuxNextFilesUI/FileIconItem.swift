import AppKit
import CmuxNextDesign
import CmuxNextFiles

/// One tile of the icon layout: a thumbnail or type icon over the name.
/// Shows a value snapshot; it never holds the model.
final class FileIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileIconItem")
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var thumbnailTask: Task<Void, Never>?
    private(set) var name: String?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 6
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        refreshTypography()
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(icon)
        root.addSubview(label)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            icon.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -16),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
        ])
        view = root
        imageView = icon
        textField = label
    }

    /// Shows `entry` at `size` points, starting a thumbnail when the type has one.
    func show(_ entry: FileEntry, size: CGFloat, icons: FileIconProvider) {
        refreshTypography()
        thumbnailTask?.cancel()
        name = entry.name
        label.stringValue = entry.name
        view.alphaValue = entry.isHidden ? 0.55 : 1
        if let cached = icons.cachedThumbnail(for: entry, size: size) {
            icon.image = cached
            return
        }
        icon.image = icons.icon(for: entry)
        guard entry.kind == .file else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        thumbnailTask = Task { [weak self] in
            guard let image = await icons.thumbnail(for: entry, size: size, scale: scale),
                  !Task.isCancelled, let self, self.name == entry.name else { return }
            self.icon.image = image
        }
    }

    /// Refreshes a mounted tile without replacing its image, selection or thumbnail request.
    func refreshTypography() {
        label.font = Typography.system(size: TypeScale.caption)
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor : nil }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        name = nil
    }
}
