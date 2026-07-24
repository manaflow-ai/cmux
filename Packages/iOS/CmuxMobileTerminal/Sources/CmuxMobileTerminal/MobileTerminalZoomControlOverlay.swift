import CMUXMobileCore
import UIKit

/// Transient, centered HUD shown while the user pinch-zooms the terminal.
///
/// It exposes three actions over the live zoom: reset to the user's saved
/// default (``onResetToDefault``), save the current size as the new default
/// (``onSaveAsDefault``), and restore the built-in default
/// (``onRestoreBuiltIn``). The host (``GhosttySurfaceView``) shows it on a zoom
/// gesture and fades it out after a few quiet seconds; any button tap fires
/// ``onInteraction`` so the host can restart that fade timer.
final class MobileTerminalZoomControlOverlay: UIView {
    /// Reset the live zoom to the user's saved default (or the built-in size).
    var onResetToDefault: (() -> Void)?
    /// Save the current live zoom as the user's default.
    var onSaveAsDefault: (() -> Void)?
    /// Restore the built-in default zoom and clear the saved default.
    var onRestoreBuiltIn: (() -> Void)?
    /// Fired on any button tap so the host can restart the auto-fade timer.
    var onInteraction: (() -> Void)?

    /// Visual treatment for the three action buttons.
    enum ButtonStyle: String {
        /// Subtle low-contrast dark fill, modest corners (current default).
        case solid
        /// iOS material/"glass" blur behind each button.
        case glass
        /// No fill — white icon + text only, with a legibility shadow.
        case plain
        /// Translucent tinted fill (`UIButton.Configuration.tinted`).
        case tinted
        /// Hairline-bordered subtle fill (`UIButton.Configuration.bordered`).
        case bordered
    }

    private let titleLabel = UILabel()
    private let titleChip = UIVisualEffectView()
    private var actionButtons: [UIButton] = []
    private let style: ButtonStyle

    init(style: ButtonStyle = MobileTerminalZoomControlOverlay.defaultStyle) {
        self.style = style
        super.init(frame: .zero)
        // No panel behind the buttons: the overlay itself is transparent and
        // each button is a standalone control, so the terminal stays visible.

        titleLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        titleLabel.textAlignment = .center
        // The readout sits in its own small glass chip (matching the buttons) so
        // it stays clearly legible over any terminal content.
        titleChip.layer.cornerRadius = 9
        titleChip.layer.cornerCurve = .continuous
        titleChip.clipsToBounds = true
        titleChip.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleChip.contentView.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: titleChip.contentView.topAnchor, constant: 4),
            titleLabel.bottomAnchor.constraint(equalTo: titleChip.contentView.bottomAnchor, constant: -4),
            titleLabel.leadingAnchor.constraint(equalTo: titleChip.contentView.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: titleChip.contentView.trailingAnchor, constant: -12),
        ])
        // Center the chip (the stack is fill-aligned) so it doesn't stretch.
        let titleRow = UIView()
        titleRow.addSubview(titleChip)
        NSLayoutConstraint.activate([
            titleChip.centerXAnchor.constraint(equalTo: titleRow.centerXAnchor),
            titleChip.topAnchor.constraint(equalTo: titleRow.topAnchor),
            titleChip.bottomAnchor.constraint(equalTo: titleRow.bottomAnchor),
        ])

        let resetButton = Self.makeButton(
            title: String(localized: "terminal.zoom.reset_to_default", defaultValue: "Reset to default"),
            systemImage: "arrow.counterclockwise",
            style: style
        )
        resetButton.addTarget(self, action: #selector(handleReset), for: .touchUpInside)
        let saveButton = Self.makeButton(
            title: String(localized: "terminal.zoom.set_as_default", defaultValue: "Set as default"),
            systemImage: "square.and.arrow.down",
            style: style
        )
        saveButton.addTarget(self, action: #selector(handleSave), for: .touchUpInside)
        let builtInButton = Self.makeButton(
            title: String(localized: "terminal.zoom.restore_built_in", defaultValue: "Restore built-in"),
            systemImage: "gobackward",
            style: style
        )
        builtInButton.addTarget(self, action: #selector(handleRestore), for: .touchUpInside)
        actionButtons = [resetButton, saveButton, builtInButton]

        let stack = UIStackView(arrangedSubviews: [titleRow, resetButton, saveButton, builtInButton])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // The overlay itself is frame-positioned by the host (centered), so only
        // its internal stack uses Auto Layout. `systemLayoutSizeFitting` derives
        // the panel size from this content.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        applyTheme(.monokai)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Updates the header to reflect the current live zoom in points.
    func updateZoom(points: Float32) {
        let value = Int(points.rounded())
        titleLabel.text = String(
            localized: "terminal.zoom.current_size",
            defaultValue: "\(value) pt"
        )
    }

    /// Recolors this transient terminal control for the active surface theme.
    func applyTheme(_ theme: TerminalTheme) {
        let background = theme.terminalBackgroundUIColor
        let foreground = background.terminalReadableForeground
        let isLight = background.terminalPrefersDarkForeground
        titleLabel.textColor = foreground
        titleChip.effect = UIBlurEffect(style: isLight ? .systemThinMaterialLight : .systemThinMaterialDark)
        for button in actionButtons {
            var config = button.configuration
            config?.baseForegroundColor = foreground
            if style == .glass {
                var background = UIBackgroundConfiguration.clear()
                background.visualEffect = UIBlurEffect(
                    style: isLight ? .systemThinMaterialLight : .systemThinMaterialDark
                )
                background.cornerRadius = 11
                config?.background = background
            }
            button.configuration = config
        }
    }

    /// The production style, overridable in DEBUG via `CMUX_UITEST_ZOOM_STYLE`
    /// so the preview harness can screenshot each treatment for comparison.
    static var defaultStyle: ButtonStyle {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_ZOOM_STYLE"],
           let style = ButtonStyle(rawValue: raw) {
            return style
        }
        #endif
        return .glass
    }

    private static func makeButton(title: String, systemImage: String, style: ButtonStyle) -> UIButton {
        var config: UIButton.Configuration
        switch style {
        case .solid:
            config = .plain()
            config.background.backgroundColor = UIColor(white: 0.0, alpha: 0.38)
            config.cornerStyle = .medium
            config.baseForegroundColor = UIColor(white: 1.0, alpha: 0.9)
        case .glass:
            config = .plain()
            var bg = UIBackgroundConfiguration.clear()
            bg.visualEffect = UIBlurEffect(style: .systemThinMaterialDark)
            bg.cornerRadius = 11
            config.background = bg
            config.baseForegroundColor = .white
        case .plain:
            config = .plain()
            config.baseForegroundColor = .white
        case .tinted:
            config = .tinted()
            config.cornerStyle = .medium
            config.baseForegroundColor = .white
        case .bordered:
            config = .bordered()
            config.cornerStyle = .medium
            config.baseForegroundColor = UIColor(white: 1.0, alpha: 0.9)
        }
        config.title = title
        config.image = UIImage(systemName: systemImage)
        config.imagePadding = 8
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 13, bottom: 8, trailing: 15)
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        if style == .plain {
            // White-on-dark needs a shadow to stay legible with no fill.
            button.titleLabel?.layer.shadowColor = UIColor.black.cgColor
            button.titleLabel?.layer.shadowOpacity = 0.8
            button.titleLabel?.layer.shadowRadius = 3
            button.titleLabel?.layer.shadowOffset = .zero
            button.imageView?.layer.shadowColor = UIColor.black.cgColor
            button.imageView?.layer.shadowOpacity = 0.8
            button.imageView?.layer.shadowRadius = 3
            button.imageView?.layer.shadowOffset = .zero
        }
        return button
    }

    @objc private func handleReset() {
        onInteraction?()
        onResetToDefault?()
    }

    @objc private func handleSave() {
        onInteraction?()
        onSaveAsDefault?()
    }

    @objc private func handleRestore() {
        onInteraction?()
        onRestoreBuiltIn?()
    }
}
