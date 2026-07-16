import AppKit
import CmuxFoundation

/// Symbol image construction for the AppKit group-header cell.
///
/// Mirrors `CmuxSystemSymbolImage`: a template symbol image configured at an
/// exact point size and weight, cached so reconfigure passes during hover or
/// scroll do not re-rasterize glyphs.
@MainActor
enum SidebarWorkspaceGroupHeaderCellSymbol {
    private struct CacheKey: Hashable {
        let systemName: String
        let pointSize: CGFloat
        let weightRawValue: CGFloat
    }

    private static var cache: [CacheKey: NSImage] = [:]
    private static var cacheInsertionOrder: [CacheKey] = []
    private static let cacheLimit = 128

    /// Returns a template symbol image at `pointSize`/`weight`, or `nil` when
    /// the symbol name is not renderable on this OS.
    static func image(
        systemName: String,
        pointSize: CGFloat,
        weight: NSFont.Weight
    ) -> NSImage? {
        let rasterSize = RenderableSystemSymbol.clampedRasterPointSize(pointSize)
        let key = CacheKey(
            systemName: systemName,
            pointSize: rasterSize,
            weightRawValue: weight.rawValue
        )
        if let cached = cache[key] {
            return cached
        }
        guard RenderableSystemSymbol.isRenderable(systemName),
              let baseImage = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: rasterSize, weight: weight)
        let configuredImage = baseImage.withSymbolConfiguration(configuration) ?? baseImage
        let image = (configuredImage.copy() as? NSImage) ?? configuredImage
        image.isTemplate = true
        image.size = RenderableSystemSymbol.symbolImageSize(
            configuredImage.size,
            fallbackDimension: rasterSize
        )
        cache[key] = image
        cacheInsertionOrder.append(key)
        while cacheInsertionOrder.count > cacheLimit {
            let evicted = cacheInsertionOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return image
    }
}

/// Borderless glyph button used for the group-header chevron and `+` controls.
///
/// Supports pass-through hit testing while invisible (the SwiftUI `+` button
/// kept its layout slot but disabled hit testing at opacity 0) and a lazy
/// right-click menu provider for the `+` button's context menu.
@MainActor
final class SidebarWorkspaceGroupHeaderCellGlyphButton: NSButton {
    /// When `false` the button is transparent to pointer events so clicks fall
    /// through to the row (table-level click handling).
    var isHitTestingEnabled = true

    /// Builds the right-click menu on demand with the currently configured
    /// snapshot and actions. Returning `nil` falls back to the responder
    /// chain (the table shows the row menu).
    var menuProvider: (() -> NSMenu?)?

    /// Invoked on left click.
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        title = ""
        setButtonType(.momentaryChange)
        focusRingType = .none
        refusesFirstResponder = true
        target = self
        action = #selector(handleClick(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isHitTestingEnabled else { return nil }
        return super.hitTest(point)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let menuProvider, let menu = menuProvider() {
            return menu
        }
        return super.menu(for: event)
    }

    @objc private func handleClick(_ sender: Any?) {
        onClick?()
    }
}

/// AppKit port of `ShortcutHintPill` rendered by `sidebarShortcutHintOverlay`:
/// a capsule material chip showing the group's modifier+digit shortcut while a
/// hint modifier is held.
@MainActor
final class SidebarWorkspaceGroupHeaderCellShortcutHintPillView: NSView {
    private let effectView = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")

    private static let horizontalTextPadding: CGFloat = 6
    private static let verticalTextPadding: CGFloat = 2
    private static let borderWidth: CGFloat = 0.8

    private var emphasis: CGFloat = 1.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.textColor = .labelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        effectView.addSubview(label)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(
                equalTo: effectView.leadingAnchor,
                constant: Self.horizontalTextPadding
            ),
            label.trailingAnchor.constraint(
                equalTo: effectView.trailingAnchor,
                constant: -Self.horizontalTextPadding
            ),
            label.topAnchor.constraint(
                equalTo: effectView.topAnchor,
                constant: Self.verticalTextPadding
            ),
            label.bottomAnchor.constraint(
                equalTo: effectView.bottomAnchor,
                constant: -Self.verticalTextPadding
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `text` at `fontSize` (already magnification-scaled) with the
    /// SwiftUI pill's emphasis-scaled border and shadow, or hides the pill
    /// entirely when `text` is `nil`.
    func configure(text: String?, fontSize: CGFloat, emphasis: CGFloat) {
        guard let text else {
            isHidden = true
            return
        }
        isHidden = false
        self.emphasis = emphasis
        label.stringValue = text
        label.font = Self.roundedMonospacedDigitFont(ofSize: fontSize, weight: .semibold)
        applyLayerStyling()
    }

    override func layout() {
        super.layout()
        let cornerRadius = bounds.height / 2
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerStyling()
    }

    private func applyLayerStyling() {
        guard let layer, let effectLayer = effectView.layer else { return }
        effectLayer.borderWidth = Self.borderWidth
        effectLayer.borderColor = NSColor.white
            .withAlphaComponent(0.30 * emphasis)
            .cgColor
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = Float(0.22 * emphasis)
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: -1)
    }

    private static func roundedMonospacedDigitFont(
        ofSize size: CGFloat,
        weight: NSFont.Weight
    ) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return rounded
    }
}
