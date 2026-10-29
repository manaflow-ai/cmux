import AppKit
import CmuxNextWakeups

/// One tile: the thumbnail (a photo or film symbol until it renders), the name
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

    /// Shows `item`, starting its thumbnail (and length) load: the cache renders off main, and each result lands on
    /// the tile as one visible task on `work` (Chrome's PostTaskAndReplyWithResult, base/task/thread_pool.h).
    func configure(_ item: FileGridItem, appearance: FileGridAppearance, cache: ThumbnailCache, work: MainWorkScheduler,
                   scale: CGFloat) {
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
        let isVideo = item.kind == .video
        // task-owner: stored in load; prepareForReuse and the next item cancel it
        load = Task { @concurrent [weak self] in
            if let image = await cache.thumbnail(for: item, side: side, scale: scale), !Task.isCancelled {
                work.postFromAnyThread(.visible, owner: "FileGrid.thumbnail") { [weak self] in self?.show(image, of: item) }
            }
            guard isVideo, let seconds = await cache.duration(for: item), !Task.isCancelled, self != nil else { return }
            work.postFromAnyThread(.visible, owner: "FileGrid.length") { [weak self] in self?.showLength(seconds, of: item) }
        }
    }

    /// The rendered thumbnail of `item`, when the tile still shows it.
    private func show(_ image: CGImage, of item: FileGridItem) {
        guard self.item == item else { return }
        picture.image = NSImage(cgImage: image, size: .zero)
    }

    /// A movie's length in the corner badge, when the tile still shows it.
    private func showLength(_ seconds: TimeInterval, of item: FileGridItem) {
        guard self.item == item else { return }
        badge.stringValue = FileGridDurationText().string(for: seconds)
        badge.isHidden = false
        view.needsLayout = true
    }

    private func applySelection() {
        view.layer?.backgroundColor = isSelected ? appearanceValues.selection.cgColor : nil
    }

    /// What a tile shows until its thumbnail renders: the photo or film symbol, with no Launch Services icon
    /// lookup on the main thread (a screenful of tiles asked it once per tile).
    private static func icon(for item: FileGridItem) -> NSImage {
        NSImage(systemSymbolName: item.kind == .video ? "film" : "photo", accessibilityDescription: nil) ?? NSImage()
    }
}
