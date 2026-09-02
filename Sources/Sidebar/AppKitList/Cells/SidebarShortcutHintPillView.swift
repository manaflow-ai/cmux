import AppKit
import CmuxSettings

/// AppKit rendition of the sidebar shortcut-hint capsule.
@MainActor
final class SidebarShortcutHintPillView: NSView {
    private static let horizontalPadding: CGFloat = 4
    private static let visibilityAnimationKey = "shortcutHintVisibility"

    private let materialView = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private let reduceMotionProvider: () -> Bool
    private var emphasis: Double = 1.0
    private var chromePalette = ChromePaletteRuntimeResolver(runtime: nil).resolve()
    private var representedIdentity: UUID?
    private var isRevealed = false
    private var visibilityGeneration: UInt64 = 0

    init(
        reduceMotionProvider: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        self.reduceMotionProvider = reduceMotionProvider
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        materialView.material = .popover
        materialView.state = .active
        materialView.blendingMode = .withinWindow
        materialView.wantsLayer = true
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 0.8
        addSubview(materialView)

        label.alignment = .center
        label.lineBreakMode = .byClipping
        materialView.addSubview(label)
        layer?.opacity = 0
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        text: String?,
        fontSize: CGFloat,
        emphasis: Double,
        representedIdentity: UUID? = nil,
        chromePalette: ChromePalette? = nil
    ) {
        let chromePalette = chromePalette
            ?? AppDelegate.shared?.chromePaletteSnapshot()
            ?? ChromePaletteRuntimeResolver(runtime: AppDelegate.shared?.settingsRuntime).resolve()
        let identityChanged = self.representedIdentity != representedIdentity
        self.representedIdentity = representedIdentity
        self.chromePalette = chromePalette
        guard let text else {
            setRevealed(false, animated: !identityChanged)
            return
        }
        self.emphasis = emphasis
        label.stringValue = text
        label.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        label.textColor = (chromePalette[.textPrimary]).cmuxNSColor
        materialView.layer?.borderColor = (chromePalette[.border]).cmuxNSColor
            .withAlphaComponent(0.30 * emphasis)
            .cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.22 * emphasis).cgColor
        setRevealed(true, animated: !identityChanged)
    }

    func fittingPillSize() -> NSSize {
        guard !isHidden else { return .zero }
        let textSize = label.sidebarNaturalCellSize
        return NSSize(
            width: ceil(textSize.width) + Self.horizontalPadding * 2,
            height: ceil(textSize.height) + 4
        )
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        materialView.frame = bounds
        materialView.layer?.cornerRadius = radius
        label.frame = materialView.bounds.insetBy(dx: Self.horizontalPadding, dy: 2)
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func resetForReuse() {
        representedIdentity = nil
        isRevealed = false
        visibilityGeneration &+= 1
        applyImmediateVisibility(false)
        label.stringValue = ""
    }

    private func setRevealed(_ revealed: Bool, animated: Bool = true) {
        if !animated {
            isRevealed = revealed
            visibilityGeneration &+= 1
            applyImmediateVisibility(revealed)
            return
        }
        guard isRevealed != revealed else { return }
        isRevealed = revealed
        visibilityGeneration &+= 1
        let generation = visibilityGeneration

        if reduceMotionProvider() {
            applyImmediateVisibility(revealed)
            return
        }

        if revealed {
            if isHidden {
                layer?.opacity = 0
                isHidden = false
            }
            animateOpacity(to: 1, generation: generation)
        } else {
            guard !isHidden else {
                layer?.opacity = 0
                return
            }
            animateOpacity(to: 0, generation: generation, hidesWhenFinished: true)
        }
    }

    private func applyImmediateVisibility(_ revealed: Bool) {
        layer?.removeAnimation(forKey: Self.visibilityAnimationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = revealed ? 1 : 0
        CATransaction.commit()
        isHidden = !revealed
    }

    private func animateOpacity(
        to value: Float,
        generation: UInt64,
        hidesWhenFinished: Bool = false
    ) {
        guard let layer else { return }
        let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = currentOpacity
        animation.toValue = value
        animation.duration = ShortcutHintAnimation.visibilityDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hidesWhenFinished {
            CATransaction.setCompletionBlock { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.visibilityGeneration == generation,
                          !self.isRevealed else { return }
                    self.isHidden = true
                }
            }
        }
        layer.opacity = value
        layer.add(animation, forKey: Self.visibilityAnimationKey)
        CATransaction.commit()
    }
}
