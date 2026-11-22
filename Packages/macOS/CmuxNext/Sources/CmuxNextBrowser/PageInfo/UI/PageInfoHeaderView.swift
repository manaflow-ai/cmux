import AppKit
import CmuxNextDesign

/// Bubble header: the site name (main page) or back button, subpage title
/// and site (subpages), plus the close button.
final class PageInfoHeaderView: NSView {
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?

    init(title: String, subtitle: String?, showsBack: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = PageInfoStyle.label(title, font: PageInfoStyle.titleFont, color: PageInfoStyle.text)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let subtitleLabel = PageInfoStyle.label(subtitle ?? "", font: PageInfoStyle.captionFont, color: PageInfoStyle.secondaryText)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.isHidden = subtitle == nil
        let texts = NSStackView(views: [titleLabel, subtitleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.translatesAutoresizingMaskIntoConstraints = false
        let close = PageInfoIconButton(symbol: "xmark", label: PageInfoStrings.close) { [weak self] in self?.onClose?() }
        addSubview(texts)
        addSubview(close)
        var constraints = [
            close.trailingAnchor.constraint(equalTo: trailingAnchor),
            close.topAnchor.constraint(equalTo: topAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -PageInfoStyle.spacing),
            texts.centerYAnchor.constraint(equalTo: close.centerYAnchor).withPriority(.defaultLow),
            texts.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: texts.bottomAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: close.bottomAnchor),
        ]
        if showsBack {
            let back = PageInfoIconButton(symbol: "arrow.left", label: PageInfoStrings.back) { [weak self] in self?.onBack?() }
            addSubview(back)
            constraints += [
                back.leadingAnchor.constraint(equalTo: leadingAnchor),
                back.topAnchor.constraint(equalTo: topAnchor),
                texts.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: PageInfoStyle.spacing),
            ]
        } else {
            constraints.append(texts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PageInfoStyle.rowInset))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Small square icon button (close, back) with gray hover.
final class PageInfoIconButton: NSButton {
    private let handler: () -> Void
    private var tracking: NSTrackingArea?

    init(symbol: String, label: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        focusRingType = .none
        image = PageInfoStyle.symbol(symbol, size: PageInfoStyle.iconSize - 2, weight: .medium)
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = PageInfoStyle.itemCornerRadius
        target = self
        action = #selector(press)
        let side = PageInfoStyle.rowHeight - 4
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func press() { handler() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private var isHovering = false { didSet { applyColors() } }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            layer?.backgroundColor = (isHovering ? PageInfoStyle.hover : .clear).cgColor
            contentTintColor = PageInfoStyle.secondaryText
        }
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
