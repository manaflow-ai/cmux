#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// What the gallery's "Set" applies.
enum ConversationBackgroundChoice {
    case none
    case draft(ConversationBackgroundDraft)
    case photo(PickedPhoto)

    /// Crosses from the photo picker's loading queue to the main actor once; never mutated.
    struct PickedPhoto: @unchecked Sendable {
        var data: Data
        var mimeType: String
        var width: Int
        var height: Int
        var luminance: Double
        var image: CGImage
    }
}

/// The background gallery (ChatKit's CKBackgroundGalleryViewController): a
/// live preview of the conversation over the candidate background, the
/// categories (None, Color, Photo, Sky, Water, Aurora, Glitter) and the
/// looks of the selected one. "Set" applies it for everyone.
final class ConversationBackgroundPickerViewController: UIViewController, PHPickerViewControllerDelegate {
    var onSet: ((ConversationBackgroundChoice) -> Void)?

    private var choice: ConversationBackgroundChoice
    private var kind: ConversationBackground.Kind?
    private let preview = ConversationBackgroundPreview()
    private let categories = UIStackView()
    private let looks = UIStackView()
    private let looksScroll = UIScrollView()
    private let colorWell = UIColorWell()
    private var categoryButtons: [ConversationBackground.Kind?: ConversationBackgroundTile] = [:]
    private var lookButtons: [String: ConversationBackgroundTile] = [:]

    static let categoryOrder: [ConversationBackground.Kind?] = [nil, .photo, .color, .sky, .water, .aurora, .glitter]

    init(current: ConversationBackground?) {
        if let current {
            if current.kind == .photo {
                // The current photo stays until another is picked.
                choice = .draft(ConversationBackgroundDraft(kind: .photo, colors: current.colors, look: current.look, luminance: current.luminance))
            } else {
                choice = .draft(ConversationBackgroundDraft(kind: current.kind, colors: current.colors, look: current.look, luminance: current.luminance))
            }
            kind = current.kind
        } else {
            choice = .none
            kind = nil
        }
        self.current = current
        super.init(nibName: nil, bundle: nil)
    }

    private let current: ConversationBackground?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = ConversationBackgroundStrings.editBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let set = UIBarButtonItem(title: ConversationBackgroundStrings.set, primaryAction: UIAction { [weak self] _ in self?.commit() })
        set.style = .done
        set.accessibilityIdentifier = "conversation.background.set"
        navigationItem.rightBarButtonItem = set

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.layer.cornerRadius = 28
        preview.layer.cornerCurve = .continuous
        preview.clipsToBounds = true
        view.addSubview(preview)

        let categoryScroll = UIScrollView()
        categoryScroll.showsHorizontalScrollIndicator = false
        categoryScroll.translatesAutoresizingMaskIntoConstraints = false
        categories.axis = .horizontal
        categories.spacing = 12
        categories.translatesAutoresizingMaskIntoConstraints = false
        categoryScroll.addSubview(categories)
        view.addSubview(categoryScroll)
        for kind in Self.categoryOrder {
            let tile = ConversationBackgroundTile(style: .category)
            let title = kind.map(ConversationBackgroundStrings.name) ?? ConversationBackgroundStrings.none
            tile.configure(title: title, background: kind.flatMap(Self.sample(for:)), symbol: Self.symbol(for: kind))
            tile.accessibilityIdentifier = "conversation.background.category.\(kind?.rawValue ?? "none")"
            tile.addAction(UIAction { [weak self] _ in self?.selectCategory(kind) }, for: .primaryActionTriggered)
            categories.addArrangedSubview(tile)
            categoryButtons[kind] = tile
        }

        looksScroll.showsHorizontalScrollIndicator = false
        looksScroll.translatesAutoresizingMaskIntoConstraints = false
        looks.axis = .horizontal
        looks.spacing = 14
        looks.alignment = .center
        looks.translatesAutoresizingMaskIntoConstraints = false
        looksScroll.addSubview(looks)
        view.addSubview(looksScroll)
        colorWell.title = ConversationBackgroundStrings.backgroundColor
        colorWell.supportsAlpha = false
        colorWell.accessibilityLabel = ConversationBackgroundStrings.backgroundColor
        colorWell.addAction(UIAction { [weak self] _ in self?.pickedColor() }, for: .valueChanged)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            preview.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            preview.widthAnchor.constraint(equalTo: preview.heightAnchor, multiplier: 0.56),
            preview.bottomAnchor.constraint(equalTo: categoryScroll.topAnchor, constant: -20),
            categoryScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            categoryScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            categoryScroll.heightAnchor.constraint(equalToConstant: ConversationBackgroundTile.categorySize.height + 22),
            categoryScroll.bottomAnchor.constraint(equalTo: looksScroll.topAnchor, constant: -12),
            categories.topAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.topAnchor),
            categories.bottomAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.bottomAnchor),
            categories.leadingAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.leadingAnchor, constant: 20),
            categories.trailingAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.trailingAnchor, constant: -20),
            categories.heightAnchor.constraint(equalTo: categoryScroll.frameLayoutGuide.heightAnchor),
            looksScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            looksScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            looksScroll.heightAnchor.constraint(equalToConstant: ConversationBackgroundTile.lookSize.height + 22),
            looksScroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            looks.topAnchor.constraint(equalTo: looksScroll.contentLayoutGuide.topAnchor),
            looks.bottomAnchor.constraint(equalTo: looksScroll.contentLayoutGuide.bottomAnchor),
            looks.leadingAnchor.constraint(equalTo: looksScroll.contentLayoutGuide.leadingAnchor, constant: 20),
            looks.trailingAnchor.constraint(equalTo: looksScroll.contentLayoutGuide.trailingAnchor, constant: -20),
            looks.heightAnchor.constraint(equalTo: looksScroll.frameLayoutGuide.heightAnchor),
        ])
        if let current, current.kind == .photo {
            preview.show(current)
        } else {
            refreshPreview()
        }
        rebuildLooks()
        refreshSelection()
    }

    // MARK: Choosing

    private func selectCategory(_ kind: ConversationBackground.Kind?) {
        guard let kind else {
            self.kind = nil
            choice = .none
            refresh()
            return
        }
        if kind == .photo {
            presentPhotoPicker()
            return
        }
        self.kind = kind
        if case let .draft(draft) = choice, draft.kind == kind {
            // Already showing this category.
        } else if let first = ConversationBackgroundLook.looks(for: kind).first {
            choice = .draft(ConversationBackgroundDraft(look: first))
        }
        refresh()
    }

    private func selectLook(_ look: ConversationBackgroundLook) {
        choice = .draft(ConversationBackgroundDraft(look: look))
        refresh()
    }

    private func pickedColor() {
        guard let color = colorWell.selectedColor else { return }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        choice = .draft(.color(ConversationBackground.hex(r: Double(r), g: Double(g), b: Double(b))))
        kind = .color
        refresh()
    }

    #if DEBUG
    func selectCategoryFromLab(_ kind: ConversationBackground.Kind?) { selectCategory(kind) }
    func selectLookFromLab(_ look: ConversationBackgroundLook) { selectLook(look) }
    func selectColorFromLab(_ color: UIColor) {
        colorWell.selectedColor = color
        pickedColor()
    }
    func labCommit() { commit() }
    #endif

    private func commit() {
        // The current photo, untouched: nothing to set.
        if case let .draft(draft) = choice, draft.kind == .photo {
            dismiss(animated: true)
            return
        }
        onSet?(choice)
        dismiss(animated: true)
    }

    private func refresh() {
        refreshPreview()
        rebuildLooks()
        refreshSelection()
    }

    private func refreshPreview() {
        switch choice {
        case .none:
            preview.show(nil)
        case let .draft(draft):
            if draft.kind == .photo, let current {
                preview.show(current)
            } else {
                preview.show(draft.optimisticBackground(id: "preview:\(draft.look ?? draft.colors.joined())", setBy: nil))
            }
        case let .photo(photo):
            preview.show(
                ConversationBackground(id: "preview:photo", kind: .photo, photo: .init(url: nil, width: photo.width, height: photo.height), luminance: photo.luminance),
                image: photo.image
            )
        }
    }

    private func rebuildLooks() {
        looks.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lookButtons = [:]
        guard let kind, kind != .photo else { return }
        for look in ConversationBackgroundLook.looks(for: kind) {
            let tile = ConversationBackgroundTile(style: .look)
            tile.configure(title: ConversationBackgroundStrings.name(look), background: ConversationBackgroundDraft(look: look).optimisticBackground(id: look.id, setBy: nil), symbol: nil)
            tile.accessibilityIdentifier = "conversation.background.look.\(look.id)"
            tile.addAction(UIAction { [weak self] _ in self?.selectLook(look) }, for: .primaryActionTriggered)
            looks.addArrangedSubview(tile)
            lookButtons[look.id] = tile
        }
        if kind == .color { looks.addArrangedSubview(colorWell) }
    }

    private func refreshSelection() {
        let selectedLook: String?
        let selectedKind: ConversationBackground.Kind?
        switch choice {
        case .none:
            selectedLook = nil
            selectedKind = nil
        case let .draft(draft):
            selectedLook = draft.look
            selectedKind = draft.kind
        case .photo:
            selectedLook = nil
            selectedKind = .photo
        }
        for (kind, tile) in categoryButtons { tile.isSelected = kind == selectedKind }
        for (id, tile) in lookButtons { tile.isSelected = id == selectedLook }
    }

    // MARK: Photo

    private func presentPhotoPicker() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
            let picked = data.flatMap(Self.preparePhoto)
            Task { @MainActor [weak self] in
                guard let self, let picked else { return }
                self.kind = .photo
                self.choice = .photo(picked)
                self.refresh()
            }
        }
    }

    /// Downsamples to at most 2048 px on the long edge, re-encodes as JPEG
    /// and measures the luminance every device will use for contrast.
    nonisolated static func preparePhoto(_ data: Data) -> ConversationBackgroundChoice.PickedPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let luminance = ConversationBackground.luminance(of: image),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { return nil }
        return .init(data: jpeg, mimeType: "image/jpeg", width: image.width, height: image.height, luminance: luminance, image: image)
    }

    // MARK: Samples

    /// The tile art for a category: its first look.
    static func sample(for kind: ConversationBackground.Kind) -> ConversationBackground? {
        guard let look = ConversationBackgroundLook.looks(for: kind).first else { return nil }
        return ConversationBackgroundDraft(look: look).optimisticBackground(id: "tile:\(look.id)", setBy: nil)
    }

    static func symbol(for kind: ConversationBackground.Kind?) -> String? {
        switch kind {
        case nil: return "circle.slash"
        case .photo: return "photo"
        default: return nil
        }
    }
}

/// A category or look tile: background art with a caption, selectable.
final class ConversationBackgroundTile: UIControl {
    enum Style {
        case category
        case look
    }

    static let categorySize = CGSize(width: 72, height: 96)
    static let lookSize = CGSize(width: 52, height: 52)

    private let style: Style
    private let art = ConversationBackdropView()
    private let symbolView = UIImageView()
    private let caption = UILabel()
    private let ring = CAShapeLayer()

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        let size = style == .category ? Self.categorySize : Self.lookSize
        art.isUserInteractionEnabled = false
        art.layer.cornerRadius = style == .category ? 14 : size.width / 2
        art.layer.cornerCurve = .continuous
        art.backgroundColor = .secondarySystemBackground
        art.translatesAutoresizingMaskIntoConstraints = false
        addSubview(art)
        symbolView.tintColor = .secondaryLabel
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbolView)
        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.adjustsFontForContentSizeCategory = true
        caption.textAlignment = .center
        caption.textColor = .label
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)
        ring.fillColor = nil
        ring.lineWidth = 3
        layer.addSublayer(ring)
        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            art.centerXAnchor.constraint(equalTo: centerXAnchor),
            art.widthAnchor.constraint(equalToConstant: size.width),
            art.heightAnchor.constraint(equalToConstant: size.height),
            symbolView.centerXAnchor.constraint(equalTo: art.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: art.centerYAnchor),
            caption.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 4),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: size.width + 6),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, background: ConversationBackground?, symbol: String?) {
        caption.text = style == .category ? title : nil
        caption.isHidden = style == .look
        accessibilityLabel = title
        art.show(background, animated: false)
        symbolView.image = symbol.flatMap { UIImage(systemName: $0) }
    }

    override var isSelected: Bool {
        didSet {
            accessibilityTraits = isSelected ? [.button, .selected] : .button
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = art.frame.insetBy(dx: -3, dy: -3)
        ring.path = UIBezierPath(roundedRect: frame, cornerRadius: art.layer.cornerRadius + 3).cgPath
        ring.strokeColor = isSelected ? tintColor.cgColor : UIColor.clear.cgColor
    }
}

/// The gallery's preview: the background with incoming and outgoing
/// bubbles (no text), styled the way the transcript will be over it.
final class ConversationBackgroundPreview: UIView {
    private let backdrop = ConversationBackdropView()
    private let incoming = [BubbleBackgroundView(), BubbleBackgroundView()]
    private let outgoing = [BubbleBackgroundView(), BubbleBackgroundView()]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ConversationTheme.background
        accessibilityElementsHidden = true
        addSubview(backdrop)
        for (index, bubble) in incoming.enumerated() {
            bubble.side = .leading
            bubble.hasTail = index == incoming.count - 1
            bubble.fillColor = ConversationTheme.incomingBubble
            bubble.adaptsToBackdrop = true
            addSubview(bubble)
        }
        for (index, bubble) in outgoing.enumerated() {
            bubble.side = .trailing
            bubble.hasTail = index == outgoing.count - 1
            bubble.fillColor = ConversationTheme.outgoingBubble
            bubble.screenGradient = ConversationTheme.iMessageGradient
            addSubview(bubble)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ background: ConversationBackground?, image: CGImage? = nil) {
        if let image, let background {
            backdrop.backdrop.set(background, image: image, animated: true)
        } else {
            backdrop.show(background, animated: true)
        }
        if let background {
            traitOverrides.userInterfaceStyle = background.prefersDarkContent ? .dark : .light
            traitOverrides.isOverConversationBackdrop = true
        } else {
            if traitOverrides.contains(UITraitUserInterfaceStyle.self) { traitOverrides.remove(UITraitUserInterfaceStyle.self) }
            if traitOverrides.contains(ConversationBackdropTrait.self) { traitOverrides.remove(ConversationBackdropTrait.self) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        // A quarter-scale transcript: two incoming, then two outgoing bubbles.
        let height: CGFloat = 22
        var y = bounds.height * 0.4
        for (bubble, fraction) in zip(incoming, [0.42, 0.6]) {
            bubble.frame = CGRect(x: 12, y: y, width: bounds.width * fraction, height: height)
            y = bubble.frame.maxY + 4
        }
        y += 10
        for (bubble, fraction) in zip(outgoing, [0.5, 0.36]) {
            let width = bounds.width * fraction
            bubble.frame = CGRect(x: bounds.width - 12 - width, y: y, width: width, height: height)
            y = bubble.frame.maxY + 4
        }
    }
}
#endif
