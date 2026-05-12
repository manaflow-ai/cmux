import AppKit

@MainActor
final class FileDropHintBadgeView: NSView {
    private static let neutralBackgroundColor = NSColor.systemGray.withAlphaComponent(0.20)
    private let effectView: NSView
    private let label = NSTextField(labelWithString: "")
    private var animationGeneration: UInt64 = 0

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            effectView = glassClass.init(frame: .zero)
        } else {
            let visualEffect = NSVisualEffectView(frame: .zero)
            visualEffect.material = .hudWindow
            visualEffect.blendingMode = .withinWindow
            visualEffect.state = .active
            effectView = visualEffect
        }

        super.init(frame: frameRect)
        frame.size = CGSize(width: 140, height: 26)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        alphaValue = 0
        isHidden = true

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.wantsLayer = true
        effectView.layer?.backgroundColor = Self.neutralBackgroundColor.cgColor
        effectView.layer?.cornerRadius = 13
        effectView.layer?.masksToBounds = true
        configureNativeGlassIfNeeded(effectView)
        addSubview(effectView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label, positioned: .above, relativeTo: effectView)

        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(text: String, centeredIn targetBounds: CGRect, clippedTo bounds: CGRect) {
        animationGeneration &+= 1
        label.stringValue = text
        let fitting = label.intrinsicContentSize
        let maxWidth = max(80, min(bounds.width, targetBounds.width) - 16)
        let width = min(max(140, fitting.width + 20), maxWidth)
        let height: CGFloat = 26
        let origin = CGPoint(
            x: min(max(targetBounds.midX - width / 2, bounds.minX + 8), max(bounds.minX + 8, bounds.maxX - width - 8)),
            y: min(max(targetBounds.midY - height / 2, bounds.minY + 8), max(bounds.minY + 8, bounds.maxY - height - 8))
        )
        frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        if isHidden {
            alphaValue = 0
            isHidden = false
            animator().alphaValue = 1
        } else {
            alphaValue = 1
        }
    }

    func hide() {
        guard !isHidden else { return }
        animationGeneration &+= 1
        let generation = animationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.animationGeneration == generation else { return }
                self.isHidden = true
            }
        }
    }

    private func configureNativeGlassIfNeeded(_ view: NSView) {
        guard view.className == "NSGlassEffectView" else { return }

        let tintSelector = NSSelectorFromString("setTintColor:")
        if view.responds(to: tintSelector) {
            view.perform(tintSelector, with: Self.neutralBackgroundColor)
        }
    }
}
