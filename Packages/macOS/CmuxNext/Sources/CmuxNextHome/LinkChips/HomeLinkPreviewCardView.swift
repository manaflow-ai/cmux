import AppKit
import CmuxNextDesign
import MessagesLabHome

/// The body of a link chip's hover card: the kind's icon and the live title with its state, a row
/// for where the target is, a few content lines, then a thumbnail when there is one. One instance
/// is reused for every chip; the app's one hover card panel hosts it.
final class HomeLinkPreviewCardView: NSView, HoverCardTextReporting {
    static let cardWidth: CGFloat = 300
    private static var padding: CGFloat { Metrics.space4 }
    private static let thumbnailHeight: CGFloat = 150

    let icon = NSImageView()
    let titleLabel = ChromeLabel(wrappingLabelWithString: "")
    let statusLabel = ChromeLabel(labelWithString: "")
    let placeRow = HoverCardRowView()
    let linesLabel = ChromeLabel(wrappingLabelWithString: "")
    private let thumbnail = NSView()
    private var thumbnailHeight: NSLayoutConstraint?
    private var linesTop: NSLayoutConstraint?
    private var thumbnailTop: NSLayoutConstraint?
    private(set) var preview: HomeLinkPreview?

    init() {
        super.init(frame: .zero)
        titleLabel.font = Typography.bodyEmphasized
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding - 80
        statusLabel.font = Typography.body
        linesLabel.maximumNumberOfLines = 6
        linesLabel.lineBreakMode = .byTruncatingTail
        linesLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding
        icon.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = Metrics.itemCornerRadius
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.contentsGravity = .resizeAspectFill
        for view in [icon, titleLabel, statusLabel, placeRow, linesLabel, thumbnail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let p = Self.padding, iconSize = HoverCardRowView.iconSize
        let linesTop = linesLabel.topAnchor.constraint(equalTo: placeRow.bottomAnchor, constant: Metrics.space2)
        let thumbnailTop = thumbnail.topAnchor.constraint(equalTo: linesLabel.bottomAnchor, constant: Metrics.space2)
        let height = thumbnail.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.cardWidth),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize),
            icon.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -iconSize / 3),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: p),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Metrics.space2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -Metrics.space2),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            statusLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            placeRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Metrics.space2),
            placeRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            placeRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            linesTop,
            linesLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            linesLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            thumbnailTop,
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            thumbnail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            thumbnail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p),
            height,
        ])
        self.linesTop = linesTop
        self.thumbnailTop = thumbnailTop
        thumbnailHeight = height
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ preview: HomeLinkPreview) {
        self.preview = preview
        icon.image = NSImage(systemSymbolName: preview.kind.symbolName, accessibilityDescription: nil)
        titleLabel.stringValue = preview.title
        statusLabel.stringValue = preview.status ?? ""
        statusLabel.isHidden = (preview.status ?? "").isEmpty
        if let place = preview.place, !place.isEmpty {
            placeRow.configure(HoverCardRowContent(text: place), image: nil, truncation: .byTruncatingMiddle)
            placeRow.isHidden = false
        } else {
            placeRow.isHidden = true
        }
        linesLabel.font = preview.monospaced ? Typography.system(.monospaced, size: Typography.caption.pointSize, weight: .regular) : Typography.body
        linesLabel.stringValue = preview.lines.joined(separator: "\n")
        linesLabel.isHidden = preview.lines.isEmpty
        linesTop?.constant = preview.lines.isEmpty ? 0 : Metrics.space2
        thumbnail.layer?.contents = preview.thumbnail
        thumbnail.isHidden = preview.thumbnail == nil
        thumbnailHeight?.constant = preview.thumbnail == nil ? 0 : Self.thumbnailHeight
        thumbnailTop?.constant = preview.thumbnail == nil ? 0 : Metrics.space2
        applyColors()
    }

    /// Colors in the card's theme scope (the transcript's); the panel runs it on adopt and on
    /// every theme change.
    func applyColors() {
        performWithTheme {
            icon.contentTintColor = Palette.textSecondary
            titleLabel.textColor = Palette.textPrimary
            statusLabel.textColor = (preview?.statusTone ?? .secondary).color
            linesLabel.textColor = Palette.textSecondary
            thumbnail.layer?.backgroundColor = Palette.hoverFill.cgColor
        }
        placeRow.applyColors()
    }

    var reportedLines: [String] {
        guard let preview else { return [] }
        return [preview.title, preview.status, preview.place].compactMap { $0 } + preview.lines
    }
}
