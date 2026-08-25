import AppKit
import CmuxAppKitSupportUI

/// Displays either an appearance-aware symbol or a compact language badge.
@MainActor
final class FileExplorerIconView: NSView {
    private let symbolView = CmuxResolvedIconImageView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private var descriptor: FileExplorerIconDescriptor?
    private var iconSize: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        descriptor: FileExplorerIconDescriptor,
        size: CGFloat,
        symbolWeight: NSFont.Weight
    ) {
        self.descriptor = descriptor
        iconSize = size
        switch descriptor.kind {
        case .symbol(let name):
            badgeLabel.isHidden = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.cornerRadius = 0
            symbolView.isHidden = false
            symbolView.apply(CmuxResolvedIconRequest(
                source: .systemSymbol(name: name, accessibilityDescription: nil),
                size: NSSize(width: size, height: size),
                tintColor: color(for: descriptor.colorRole),
                symbolWeight: symbolWeight
            ))
        case .badge(let text):
            symbolView.apply(nil)
            symbolView.isHidden = true
            badgeLabel.isHidden = false
            badgeLabel.stringValue = text
            badgeLabel.font = .systemFont(
                ofSize: text.count >= 3 ? max(6, size * 0.38) : max(7, size * 0.48),
                weight: .bold
            )
            applyBadgeAppearance()
        }
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
    }

    func configure(
        image: NSImage,
        size: CGFloat,
        tintColor: NSColor
    ) {
        descriptor = nil
        iconSize = size
        badgeLabel.isHidden = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 0
        symbolView.isHidden = false
        symbolView.apply(CmuxResolvedIconRequest(
            source: .image(image),
            size: NSSize(width: size, height: size),
            tintColor: tintColor
        ))
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
    }

    func configure(
        systemSymbol name: String,
        size: CGFloat,
        tintColor: NSColor,
        symbolWeight: NSFont.Weight
    ) {
        descriptor = nil
        iconSize = size
        badgeLabel.isHidden = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 0
        symbolView.isHidden = false
        symbolView.apply(CmuxResolvedIconRequest(
            source: .systemSymbol(name: name, accessibilityDescription: nil),
            size: NSSize(width: size, height: size),
            tintColor: tintColor,
            symbolWeight: symbolWeight
        ))
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let descriptor else { return }
        if case .badge = descriptor.kind {
            applyBadgeAppearance()
        }
    }

    private func setupViews() {
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.alignment = .center
        badgeLabel.lineBreakMode = .byClipping
        badgeLabel.maximumNumberOfLines = 1
        badgeLabel.isBordered = false
        badgeLabel.drawsBackground = false
        badgeLabel.setAccessibilityElement(false)
        addSubview(symbolView)
        addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbolView.trailingAnchor.constraint(equalTo: trailingAnchor),
            symbolView.topAnchor.constraint(equalTo: topAnchor),
            symbolView.bottomAnchor.constraint(equalTo: bottomAnchor),
            badgeLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func applyBadgeAppearance() {
        guard let descriptor else { return }
        layer?.cornerRadius = min(5, iconSize * 0.3)
        layer?.backgroundColor = resolvedColor(
            color(for: descriptor.colorRole),
            appearance: effectiveAppearance
        ).cgColor
        badgeLabel.textColor = descriptor.prefersDarkBadgeText ? .black : .white
    }

    private func resolvedColor(_ color: NSColor, appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    private func color(for role: FileExplorerIconDescriptor.ColorRole) -> NSColor {
        switch role {
        case .blue: .systemBlue
        case .cyan: .systemCyan
        case .green: .systemGreen
        case .neutral: .secondaryLabelColor
        case .orange: .systemOrange
        case .pink: .systemPink
        case .purple: .systemPurple
        case .red: .systemRed
        case .yellow: .systemYellow
        }
    }

}
