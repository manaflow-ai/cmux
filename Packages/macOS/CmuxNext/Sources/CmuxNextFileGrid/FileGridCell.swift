import AppKit
import UniformTypeIdentifiers

/// One tile: the thumbnail (the file's icon until it renders), the name
/// under it, and a movie's length in a corner badge. Loads its picture
/// lazily from the shared ``ThumbnailCache`` and drops the request when the
/// tile scrolls away or shows another file.
final class FileGridCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.filegrid.cell")
    static let nameHeight: CGFloat = 20

    private let picture = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var load: Task<Void, Never>?
    private(set) var item: FileGridItem?
    private var appearanceValues = FileGridAppearance()

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 6
        picture.layer?.masksToBounds = true
        name.lineBreakMode = .byTruncatingMiddle
        name.alignment = .center
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        name.maximumNumberOfLines = 1
        badge.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .semibold)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        badge.alignment = .center
        badge.isHidden = true
        for view in [picture, name, badge] { root.addSubview(view) }
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        let inset: CGFloat = 6
        let side = bounds.width - 2 * inset
        picture.frame = CGRect(x: inset, y: bounds.height - inset - side, width: side, height: side)
        name.frame = CGRect(x: 2, y: max(0, picture.frame.minY - Self.nameHeight), width: bounds.width - 4, height: Self.nameHeight - 2)
        let size = badge.intrinsicContentSize
        let badgeSize = CGSize(width: size.width + 8, height: size.height + 2)
        badge.frame = CGRect(x: picture.frame.maxX - badgeSize.width - 4, y: picture.frame.minY + 4,
                             width: badgeSize.width, height: badgeSize.height)
        badge.layer?.cornerRadius = 4
    }

    override var isSelected: Bool {
        didSet { applySelection() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        load?.cancel()
        load = nil
        item = nil
        picture.image = nil
        badge.isHidden = true
    }

    /// Shows `item`, starting its thumbnail (and length) load.
    func configure(_ item: FileGridItem, appearance: FileGridAppearance, cache: ThumbnailCache, scale: CGFloat) {
        appearanceValues = appearance
        name.stringValue = item.name
        name.textColor = appearance.text
        picture.layer?.backgroundColor = appearance.tileFill.cgColor
        view.setAccessibilityLabel(item.name)
        applySelection()
        guard self.item != item else { return }
        load?.cancel()
        self.item = item
        picture.image = Self.icon(for: item)
        badge.isHidden = true
        let side = appearance.tileSide
        load = Task { @MainActor [weak self] in
            if let image = await cache.thumbnail(for: item, side: side, scale: scale) {
                guard let self, !Task.isCancelled, self.item == item else { return }
                self.picture.image = NSImage(cgImage: image, size: .zero)
            }
            guard item.kind == .video, let seconds = await cache.duration(for: item) else { return }
            guard let self, !Task.isCancelled, self.item == item else { return }
            self.badge.stringValue = FileGridDurationText().string(for: seconds)
            self.badge.isHidden = false
            self.view.needsLayout = true
        }
    }

    private func applySelection() {
        view.layer?.backgroundColor = isSelected ? appearanceValues.selection.cgColor : nil
    }

    private static func icon(for item: FileGridItem) -> NSImage {
        let type = UTType(filenameExtension: item.url.pathExtension.lowercased()) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
