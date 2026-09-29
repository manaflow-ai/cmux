#if canImport(UIKit)
import CmuxMobileTerminalKit
import QuartzCore
import UIKit

/// The text of the size chip: "118×38 · Maya's Mac Studio · scaled", and
/// the compact title ("118×38") used when the grid leaves no letterbox.
public struct TerminalSizingChipContent: Equatable, Sendable {
    public var title: String
    public var compactTitle: String
    public var accessibilityLabel: String
    public var accessibilityHint: String

    public init(
        title: String,
        compactTitle: String? = nil,
        accessibilityLabel: String,
        accessibilityHint: String
    ) {
        self.title = title
        self.compactTitle = compactTitle ?? title
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
    }
}

/// The shared-sizing bounds: a thin neutral border, a faint hatch
/// outside the grid, a short fade on cut edges, and the size chip. Only the
/// chip takes touches.
///
/// Every grey is the app's separator token (`UIColor.separator`, the color of
/// the workspace list dividers, the size sheet's dividers and the plain
/// letterbox border): the border and the chip stroke use it as is, and the
/// hatch, cut-edge fade and chip fill use half of its own opacity.
@MainActor
final class GhosttySurfaceSharedSizingLayers {
    /// Distance between hatch lines, in points.
    static let hatchSpacing: CGFloat = 8
    /// Share of the separator's opacity used by the hatch lines.
    static let hatchOpacity: CGFloat = 0.5
    /// Share of the separator's opacity used by the chip fill.
    static let chipFillOpacity: CGFloat = 0.5
    /// Distance between the chip and the grid or viewport edge, in points.
    static let chipInset: CGFloat = TerminalSizingChipPlacement.defaultInset

    /// The single grey of the sizing UI.
    static let grey = UIColor.separator

    /// `color` with its own opacity multiplied by `opacity`.
    static func derived(_ color: UIColor, opacity: CGFloat) -> UIColor {
        var alpha: CGFloat = 0
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return color.withAlphaComponent(alpha * opacity)
    }

    let container = CALayer()
    let border = CAShapeLayer()
    let hatch = CAShapeLayer()
    let hatchMask = CAShapeLayer()
    var fades: [CAGradientLayer] = []
    private(set) var chip: UIButton?

    init(host: CALayer) {
        let noActions: [String: any CAAction] = [
            "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull(),
            "opacity": NSNull(), "path": NSNull(), "position": NSNull(),
            "strokeColor": NSNull(), "sublayers": NSNull(), "colors": NSNull(),
        ]
        container.name = "cmux.sharedSizing"
        container.zPosition = 1000 // above the Ghostty renderer layer
        container.actions = noActions
        hatch.fillColor = UIColor.clear.cgColor
        hatch.lineWidth = 1
        hatch.actions = noActions
        hatchMask.actions = noActions
        hatch.mask = hatchMask
        border.fillColor = UIColor.clear.cgColor
        border.lineWidth = TerminalSizingBoundsGeometry.borderWidth
        border.actions = noActions
        container.addSublayer(hatch)
        container.addSublayer(border)
        host.addSublayer(container)
    }

    func hide() {
        container.isHidden = true
        chip?.isHidden = true
    }

    /// Shows the chip outside the grid (`TerminalSizingChipPlacement`), or
    /// hides it. It never covers the grid's last row.
    func layoutChip(
        _ content: TerminalSizingChipContent?,
        in hostView: UIView,
        gridRect: CGRect?,
        viewportRect: CGRect,
        onTap: @escaping @MainActor () -> Void
    ) {
        guard let content, let gridRect else {
            chip?.isHidden = true
            return
        }
        let button = chip ?? makeChip(in: hostView, onTap: onTap)
        chip = button
        button.accessibilityLabel = content.accessibilityLabel
        button.accessibilityHint = content.accessibilityHint
        button.isHidden = false
        let limit = CGSize(
            width: max(0, viewportRect.width - Self.chipInset * 2),
            height: .greatestFiniteMagnitude
        )
        let fullSize = fittingSize(of: button, title: content.title, limit: limit)
        let compactSize = fittingSize(of: button, title: content.compactTitle, limit: limit)
        let placement = TerminalSizingChipPlacement.place(
            chipSize: fullSize,
            compactChipSize: compactSize,
            gridRect: gridRect,
            viewportRect: viewportRect,
            inset: Self.chipInset
        )
        let title = placement.isCompact ? content.compactTitle : content.title
        if button.configuration?.title != title {
            button.configuration?.title = title
        }
        button.frame = placement.frame
        hostView.bringSubviewToFront(button)
    }

    /// The chip's fitting size for `title`, capped to `limit`'s width.
    private func fittingSize(of button: UIButton, title: String, limit: CGSize) -> CGSize {
        if button.configuration?.title != title {
            button.configuration?.title = title
        }
        var size = button.sizeThatFits(limit)
        size.width = min(size.width, limit.width)
        return size
    }

    private func makeChip(in hostView: UIView, onTap: @escaping @MainActor () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .secondaryLabel
        // The blur keeps the chip legible over terminal text; the fill and
        // stroke are the sizing grey.
        configuration.background.visualEffect = UIBlurEffect(style: .systemThinMaterial)
        configuration.background.backgroundColor = UIColor { traits in
            Self.derived(Self.grey.resolvedColor(with: traits), opacity: Self.chipFillOpacity)
        }
        configuration.background.strokeColor = Self.grey
        configuration.background.strokeWidth = TerminalSizingBoundsGeometry.borderWidth
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        configuration.titleLineBreakMode = .byTruncatingMiddle
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            let size = UIFont.preferredFont(forTextStyle: .caption2).pointSize
            attributes.font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            MainActor.assumeIsolated { onTap() }
        })
        button.accessibilityIdentifier = "MobileTerminalSizingChip"
        button.layer.zPosition = 1001 // above the bounds layers
        hostView.addSubview(button)
        return button
    }

    func apply(
        geometry: TerminalSizingBoundsGeometry,
        grey: UIColor,
        bounds: CGRect,
        scale: CGFloat
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let borderRect = geometry.borderRect else {
            container.isHidden = true
            return
        }
        container.isHidden = false
        container.frame = bounds
        container.contentsScale = scale
        for layer in [border, hatch, hatchMask] as [CALayer] {
            layer.frame = bounds
            layer.contentsScale = scale
        }

        let inset = TerminalSizingBoundsGeometry.borderWidth / 2
        border.strokeColor = grey.cgColor
        border.path = UIBezierPath(rect: borderRect.insetBy(dx: inset, dy: inset)).cgPath

        let maskPath = UIBezierPath()
        for rect in geometry.hatchRects {
            maskPath.append(UIBezierPath(rect: rect))
        }
        hatchMask.path = maskPath.cgPath
        hatch.strokeColor = Self.derived(grey, opacity: Self.hatchOpacity).cgColor
        hatch.path = geometry.hatchRects.isEmpty ? nil : Self.hatchPath(in: bounds)

        fades.forEach { $0.removeFromSuperlayer() }
        fades = geometry.cutFades.map { fade in
            let layer = CAGradientLayer()
            layer.actions = ["bounds": NSNull(), "frame": NSNull(), "position": NSNull()]
            layer.frame = fade.rect
            layer.contentsScale = scale
            layer.colors = [
                grey.withAlphaComponent(0).cgColor,
                Self.derived(grey, opacity: Self.hatchOpacity).cgColor,
            ]
            switch fade.edge {
            case .trailing:
                layer.startPoint = CGPoint(x: 0, y: 0.5)
                layer.endPoint = CGPoint(x: 1, y: 0.5)
            case .leading:
                layer.startPoint = CGPoint(x: 1, y: 0.5)
                layer.endPoint = CGPoint(x: 0, y: 0.5)
            case .top:
                layer.startPoint = CGPoint(x: 0.5, y: 1)
                layer.endPoint = CGPoint(x: 0.5, y: 0)
            case .bottom:
                layer.startPoint = CGPoint(x: 0.5, y: 0)
                layer.endPoint = CGPoint(x: 0.5, y: 1)
            }
            container.addSublayer(layer)
            return layer
        }
    }

    /// Diagonal lines across `rect`, clipped later by the hatch mask.
    static func hatchPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        var offset = -rect.height
        while offset < rect.width {
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += hatchSpacing
        }
        return path
    }
}

extension GhosttySurfaceView {
    /// Redraws the shared-sizing layers from the current decoration and the
    /// last letterbox geometry. Hides them unless the mismatch is settled
    /// (`TerminalSizingChromeGate`).
    func refreshSharedSizingLayers() {
        guard let decoration = sharedSizingDecoration,
              TerminalSizingChromeGate.drawsChrome(
                  decoration: decoration,
                  viewportReportPending: viewportReportPending
              ),
              let viewportRect = lastLetterboxViewportRect,
              !lastRenderRect.isEmpty else {
            sharedSizingLayers?.hide()
            return
        }
        let layers: GhosttySurfaceSharedSizingLayers
        if let existing = sharedSizingLayers {
            layers = existing
        } else {
            layers = GhosttySurfaceSharedSizingLayers(host: layer)
            sharedSizingLayers = layers
        }
        let geometry = decoration.geometry(viewportRect: viewportRect, renderRect: lastRenderRect)
        layers.apply(
            geometry: geometry,
            grey: GhosttySurfaceSharedSizingLayers.grey.resolvedColor(with: traitCollection),
            bounds: layer.bounds,
            scale: max(layer.contentsScale, 1)
        )
        layers.layoutChip(
            sharedSizingChip,
            in: self,
            gridRect: geometry.borderRect,
            viewportRect: viewportRect,
            onTap: { [weak self] in self?.onSharedSizingChipTap?() }
        )
    }
}
#endif
