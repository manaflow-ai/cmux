import AppKit
import CMUXMobileCore

/// Draws a pairing payload as a crisp native QR image.
@MainActor
final class MobilePairingQRImageView: NSView {
    private var payload: String
    private var image: NSImage?

    init(payload: String) {
        self.payload = payload
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        heightAnchor.constraint(equalTo: widthAnchor).isActive = true
        update(payload: payload)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 380, height: 380) }

    func update(payload: String) {
        guard self.payload != payload || image == nil else { return }
        self.payload = payload
        if let cgImage = CmxPairingQRBitmap().makeImage(payload: payload) {
            image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            )
            setAccessibilityLabel(String(
                localized: "mobile.pairing.qrAccessibilityLabel",
                defaultValue: "Pairing QR code"
            ))
        } else {
            image = nil
            setAccessibilityLabel(String(
                localized: "mobile.pairing.qrUnavailable",
                defaultValue: "Pairing code unavailable. Tap Refresh Code."
            ))
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
        if let image {
            image.draw(
                in: bounds,
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
        } else {
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: bounds).fill()
            guard let symbol = NSImage(systemSymbolName: "qrcode", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)) else {
                return
            }
            let size = symbol.size
            symbol.draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                from: .zero,
                operation: .sourceOver,
                fraction: 0.7
            )
        }
    }
}
