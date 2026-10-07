#if canImport(UIKit)
import Photos
import UIKit

/// Messages' inline Photos drawer: a 3-column grid of recent library photos
/// with hairline gutters; selected photos lighten and show a blue count badge.
@MainActor
final class ConversationPhotoGridView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    var onToggle: ((PHAsset, Bool) -> Void)?
    private var assets: PHFetchResult<PHAsset>?
    private var selection: [String] = []
    private let imageManager = PHCachingImageManager()
    private lazy var grid: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.dataSource = self
        view.delegate = self
        view.register(Cell.self, forCellWithReuseIdentifier: "p")
        view.accessibilityIdentifier = "conversation.photoGrid"
        return view
    }()
    private let message = UILabel()
    /// The sheet grabber Messages draws over the first row of photos.
    private let grabber = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        accessibilityIdentifier = "conversation.photoDrawer"
        // A card inset from the screen edges: 38 pt top corners and bottom
        // corners concentric with the display's (measured ~57 pt on iPhone 17 Pro).
        if #available(iOS 26.0, *) {
            cornerConfiguration = .corners(
                topLeftRadius: .fixed(38), topRightRadius: .fixed(38),
                bottomLeftRadius: .containerConcentric(minimum: 38), bottomRightRadius: .containerConcentric(minimum: 38)
            )
        } else {
            layer.cornerRadius = 38
            layer.cornerCurve = .continuous
        }
        clipsToBounds = true
        addSubview(grid)
        message.textAlignment = .center
        message.numberOfLines = 0
        message.textColor = .secondaryLabel
        message.font = .systemFont(ofSize: 15)
        addSubview(message)
        grabber.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        grabber.layer.cornerRadius = 2.5
        grabber.isUserInteractionEnabled = false
        addSubview(grabber)
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        grid.frame = bounds
        message.frame = bounds.insetBy(dx: 32, dy: 0)
        grabber.frame = CGRect(x: (bounds.width - 35) / 2, y: 4.7, width: 35, height: 5)
        if let layout = grid.collectionViewLayout as? UICollectionViewFlowLayout {
            // Messages: three square columns with a 5 px (1.67 pt at 3x) gutter
            // and no slack, so the outer columns run to the card's edges.
            let scale = window?.screen.scale ?? traitCollection.displayScale
            let gutter = round(1.67 * scale) / scale
            let side = (bounds.width - 2 * gutter) / 3 - 0.001
            layout.minimumInteritemSpacing = gutter
            layout.minimumLineSpacing = gutter
            layout.itemSize = CGSize(width: side, height: side)
        }
    }

    private func load() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard status == .authorized || status == .limited else {
                    self.message.text = String(localized: "conversation.photos.denied", defaultValue: "Allow access to Photos in Settings to attach photos.", bundle: .module)
                    return
                }
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                self.assets = PHAsset.fetchAssets(with: options)
                self.grid.reloadData()
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        assets?.count ?? 0
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "p", for: indexPath) as! Cell
        guard let asset = assets?.object(at: indexPath.item) else { return cell }
        cell.assetID = asset.localIdentifier
        let scale = window?.screen.scale ?? 3
        let side = (collectionView.collectionViewLayout as? UICollectionViewFlowLayout)?.itemSize.width ?? 120
        imageManager.requestImage(for: asset, targetSize: CGSize(width: side * scale, height: side * scale), contentMode: .aspectFill, options: nil) { image, _ in
            guard cell.assetID == asset.localIdentifier else { return }
            cell.imageView.image = image
        }
        cell.setBadge(selection.firstIndex(of: asset.localIdentifier).map { $0 + 1 })
        cell.accessibilityIdentifier = "conversation.photo.\(indexPath.item)"
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let asset = assets?.object(at: indexPath.item) else { return }
        let selected: Bool
        if let index = selection.firstIndex(of: asset.localIdentifier) {
            selection.remove(at: index)
            selected = false
        } else {
            selection.append(asset.localIdentifier)
            selected = true
        }
        UISelectionFeedbackGenerator().selectionChanged()
        for case let cell as Cell in collectionView.visibleCells {
            cell.setBadge(cell.assetID.flatMap { selection.firstIndex(of: $0) }.map { $0 + 1 }, animated: true)
        }
        onToggle?(asset, selected)
    }

    /// Drops one photo from the selection (its card preview was removed),
    /// renumbering the remaining badges as Messages does.
    func deselect(assetID: String) {
        guard let index = selection.firstIndex(of: assetID) else { return }
        selection.remove(at: index)
        for case let cell as Cell in grid.visibleCells {
            cell.setBadge(cell.assetID.flatMap { selection.firstIndex(of: $0) }.map { $0 + 1 }, animated: true)
        }
    }

    func clearSelection() {
        selection = []
        grid.reloadData()
    }

    private final class Cell: UICollectionViewCell {
        let imageView = UIImageView()
        private let badge = UILabel()
        var assetID: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            contentView.addSubview(imageView)
            badge.backgroundColor = UIColor(red: 0, green: 136 / 255, blue: 1, alpha: 1)
            badge.textColor = .white
            badge.font = .systemFont(ofSize: 13, weight: .semibold)
            badge.textAlignment = .center
            badge.layer.cornerRadius = 11
            badge.layer.borderWidth = 1
            badge.layer.borderColor = UIColor.white.cgColor
            badge.clipsToBounds = true
            contentView.addSubview(badge)
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func prepareForReuse() {
            super.prepareForReuse()
            imageView.image = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = contentView.bounds
            // Messages: a 22 pt badge centered 15 pt in from the bottom-right corner.
            let b = contentView.bounds
            badge.frame = CGRect(x: b.width - 15 - 11, y: b.height - 15 - 11, width: 22, height: 22)
        }

        func setBadge(_ number: Int?, animated: Bool = false) {
            badge.text = number.map(String.init)
            let show = number != nil
            guard animated, badge.isHidden == show else {
                badge.isHidden = !show
                imageView.alpha = show ? 0.75 : 1
                return
            }
            badge.isHidden = false
            badge.transform = show ? CGAffineTransform(scaleX: 0.3, y: 0.3) : .identity
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0) {
                self.badge.transform = show ? .identity : CGAffineTransform(scaleX: 0.3, y: 0.3)
                self.imageView.alpha = show ? 0.75 : 1
            } completion: { _ in
                self.badge.isHidden = !show
                self.badge.transform = .identity
            }
        }
    }
}
#endif
