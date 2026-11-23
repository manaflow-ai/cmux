#if os(iOS)
import CmuxMobileDesign
import UIKit

/// The ground under a terminal page: its Mac's wallpaper under the terminal background at the
/// Mac's tint (``CmuxMobileMacTheme/wallpaper``), as the Mac's window paints its picture and tint
/// under see-through surfaces, else the plain terminal background.
///
/// The page has one at its back, and each piece of chrome that must hide rows scrolled under it
/// (the bottom backing, the cover under a TUI, the fades) has its own, with the picture laid out
/// against the page (``page``) so the pieces line up with the ground behind them.
@MainActor
final class TerminalGroundView: UIView {
    private let picture = CALayer()
    private let tint = CALayer()
    /// The fade's alpha ramp (a fade's own gradient, as a mask); nil for a solid ground.
    private let fade: CAGradientLayer?
    /// The view the picture is laid out against: the page, whose bounds it fills.
    weak var page: UIView?
    /// Whether the picture shows (else the ground is the plain background).
    private(set) var showsPicture = false

    init(page: UIView?, fade: Bool = false) {
        self.page = page
        self.fade = fade ? CAGradientLayer() : nil
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        picture.isHidden = true
        layer.addSublayer(picture)
        layer.addSublayer(tint)
        clipsToBounds = true
        if let mask = self.fade { layer.mask = mask }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `wallpaper` under `background` at its tint, or `background` alone.
    func show(_ wallpaper: (image: UIImage, tint: Double)?, background: UIColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = wallpaper?.image.cgImage
        picture.isHidden = wallpaper == nil
        showsPicture = wallpaper != nil
        tint.backgroundColor = background.withAlphaComponent(CGFloat(wallpaper?.tint ?? 1)).cgColor
        CATransaction.commit()
        setNeedsLayout()
    }

    /// The fade's ramp: alpha 0...1 at `locations` (a mask over the whole ground).
    func setFade(alphas: [CGFloat], locations: [NSNumber]?) {
        guard let fade else { return }
        fade.colors = alphas.map { UIColor.black.withAlphaComponent($0).cgColor }
        fade.locations = locations
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        align()
    }

    /// Lays the picture out against the page (the whole page's aspect fill, seen through this view).
    func align() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pageFrame = page.map { $0.convert($0.bounds, to: self) } ?? bounds
        if picture.frame != pageFrame { picture.frame = pageFrame }
        if tint.frame != bounds { tint.frame = bounds }
        fade?.frame = bounds
        CATransaction.commit()
    }
}
#endif
