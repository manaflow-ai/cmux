public import AppKit
public import CmuxUpdater
import QuartzCore

/// Native badge showing the current update phase as a symbol, progress ring, or spinner.
@MainActor
public final class UpdateBadgeView: NSView {
    private enum Content: Equatable {
        case none
        case symbol(String)
        case progress(Double)
        case spinner
    }

    private let imageView = NSImageView()
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private var content: Content = .none
    private var tintColor: NSColor = .labelColor

    /// Creates an empty update badge.
    public init() {
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 14, height: 14)))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        widthAnchor.constraint(equalToConstant: 14).isActive = true
        heightAnchor.constraint(equalToConstant: 14).isActive = true

        wantsLayer = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        layer?.addSublayer(trackLayer)
        layer?.addSublayer(progressLayer)
        [trackLayer, progressLayer].forEach {
            $0.fillColor = NSColor.clear.cgColor
            $0.lineWidth = 2
            $0.lineCap = .round
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Applies the current model presentation.
    public func update(model: UpdateStateModel, appearance: UpdateAppearance) {
        tintColor = appearance.foregroundColor(for: model)
        setAccessibilityLabel(model.text)

        let nextContent: Content
        if model.showsDetectedBackgroundUpdate {
            nextContent = model.iconName.map(Content.symbol) ?? .none
        } else {
            switch model.effectiveState {
            case .downloading(let download):
                if let expectedLength = download.expectedLength, expectedLength > 0 {
                    nextContent = .progress(Self.clamp(Double(download.progress) / Double(expectedLength)))
                } else {
                    nextContent = .symbol("arrow.down.circle")
                }
            case .extracting(let extracting):
                nextContent = .progress(Self.clamp(extracting.progress))
            case .preparingCheck, .checking, .startingDownload:
                nextContent = .spinner
            default:
                nextContent = model.iconName.map(Content.symbol) ?? .none
            }
        }

        content = nextContent
        applyContent()
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let diameter = min(bounds.width, bounds.height) - 2
        let ringRect = NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        let path = CGPath(ellipseIn: ringRect, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        progressLayer.frame = bounds
        trackLayer.path = path
        progressLayer.path = path
        CATransaction.commit()
    }

    private func applyContent() {
        progressLayer.removeAnimation(forKey: "cmux.update.spinner")
        imageView.isHidden = true
        trackLayer.isHidden = true
        progressLayer.isHidden = true

        switch content {
        case .none:
            return
        case .symbol(let name):
            imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            imageView.contentTintColor = tintColor
            imageView.isHidden = false
        case .progress(let progress):
            configureRing(progress: progress)
        case .spinner:
            configureRing(progress: 0.28)
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = Double.pi * 2
            rotation.duration = 0.9
            rotation.repeatCount = .infinity
            rotation.isRemovedOnCompletion = false
            progressLayer.add(rotation, forKey: "cmux.update.spinner")
        }
    }

    private func configureRing(progress: Double) {
        trackLayer.strokeColor = tintColor.withAlphaComponent(0.2).cgColor
        progressLayer.strokeColor = tintColor.cgColor
        progressLayer.strokeStart = 0
        progressLayer.strokeEnd = Self.clamp(progress)
        trackLayer.isHidden = false
        progressLayer.isHidden = false
        progressLayer.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 2))
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
