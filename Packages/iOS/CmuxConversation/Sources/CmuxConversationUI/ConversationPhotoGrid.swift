#if canImport(UIKit)
import Photos
import UIKit

/// Messages' inline Photos drawer: a 3-column grid of recent library photos
/// with 2 pt gutters; selected photos show a blue count badge.
@MainActor
final class ConversationPhotoGridView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    var onToggle: ((PHAsset, Bool) -> Void)?
    private var assets: PHFetchResult<PHAsset>?
    private var selection: [String] = []
    private let imageManager = PHCachingImageManager()
    private lazy var grid: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.dataSource = self
        view.delegate = self
        view.register(Cell.self, forCellWithReuseIdentifier: "p")
        view.accessibilityIdentifier = "conversation.photoGrid"
        return view
    }()
    private let message = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        accessibilityIdentifier = "conversation.photoDrawer"
        // A card inset from the screen edges, matching the device's corner curve.
        layer.cornerRadius = 34
        layer.cornerCurve = .continuous
        clipsToBounds = true
        addSubview(grid)
        message.textAlignment = .center
        message.numberOfLines = 0
        message.textColor = .secondaryLabel
        message.font = .systemFont(ofSize: 15)
        addSubview(message)
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        grid.frame = bounds
        message.frame = bounds.insetBy(dx: 32, dy: 0)
        if let layout = grid.collectionViewLayout as? UICollectionViewFlowLayout {
            let side = floor((bounds.width - 4) / 3)
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
            badge.backgroundColor = .systemBlue
            badge.textColor = .white
            badge.font = .systemFont(ofSize: 14, weight: .semibold)
            badge.textAlignment = .center
            badge.layer.cornerRadius = 12
            badge.layer.borderWidth = 1.5
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
            badge.frame = CGRect(x: contentView.bounds.width - 30, y: 6, width: 24, height: 24)
        }

        func setBadge(_ number: Int?, animated: Bool = false) {
            badge.text = number.map(String.init)
            let show = number != nil
            guard animated, badge.isHidden == show else {
                badge.isHidden = !show
                imageView.alpha = show ? 0.82 : 1
                return
            }
            badge.isHidden = false
            badge.transform = show ? CGAffineTransform(scaleX: 0.3, y: 0.3) : .identity
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0) {
                self.badge.transform = show ? .identity : CGAffineTransform(scaleX: 0.3, y: 0.3)
                self.imageView.alpha = show ? 0.82 : 1
            } completion: { _ in
                self.badge.isHidden = !show
                self.badge.transform = .identity
            }
        }
    }
}
#endif
