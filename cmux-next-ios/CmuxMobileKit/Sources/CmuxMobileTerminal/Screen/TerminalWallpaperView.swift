#if os(iOS)
import CmuxMobileDesign
import UIKit

/// The Mac's wallpaper behind the terminal page (ask-a6804c4472): the picture, filled over the
/// whole page, under the terminal theme's background at the Mac's tint, the same ground the chat
/// draws (`CmuxMobileChatBackdrop`). The page itself and each backing over the rows (the bottom
/// chrome's, the TUI's cover) show it, each the slice under it, so the picture reads as one
/// sheet behind the surface, the key bar and the composer. Without a picture it is the plain
/// background.
final class TerminalWallpaperView: UIView {
    /// The view whose bounds the picture fills (the page); nil fills this view.
    weak var page: UIView?
    private let picture = UIImageView()
    private let tint = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.isHidden = true
        tint.isHidden = true
        addSubview(picture)
        addSubview(tint)
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether the picture shows now.
    var showsPicture: Bool { !picture.isHidden }

    /// Shows `image` under `background` at `opacity`, or `background` alone without one.
    func show(_ image: UIImage?, background: UIColor, opacity: Double) {
        picture.image = image
        picture.isHidden = image == nil
        tint.isHidden = image == nil
        tint.backgroundColor = background.withAlphaComponent(opacity)
        backgroundColor = image == nil ? background : .clear
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tint.frame = bounds
        let sheet = page.map { convert($0.bounds, from: $0) } ?? bounds
        if picture.frame != sheet { picture.frame = sheet }
    }
}
#endif
