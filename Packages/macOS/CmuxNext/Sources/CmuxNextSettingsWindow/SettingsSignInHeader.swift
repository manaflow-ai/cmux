public import AppKit
import CmuxNextDesign
public import Foundation

/// The read-only address and controls above Settings' sign-in browser.
@MainActor
public final class SettingsSignInHeader: NSView {
    private let hostLabel = NSTextField(labelWithString: "")
    private let reloadButton = TitlebarBandButton(symbol: "arrow.clockwise")
    private let closeButton = TitlebarBandButton(symbol: "xmark")
    private let reload: () -> Void
    private let close: () -> Void

    public init(reload: @escaping () -> Void, close: @escaping () -> Void) {
        self.reload = reload
        self.close = close
        super.init(frame: .zero)

        hostLabel.font = Typography.caption
        hostLabel.textColor = .labelColor
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let reloadTitle = String(localized: "settingsWindow.models.browser.reload", defaultValue: "Reload This Page", bundle: .module)
        let closeTitle = String(localized: "settingsWindow.studio.close", defaultValue: "Close", bundle: .module)
        reloadButton.setAccessibilityLabel(reloadTitle)
        reloadButton.toolTip = reloadTitle
        reloadButton.target = self
        reloadButton.action = #selector(reloadPage)
        closeButton.setAccessibilityLabel(closeTitle)
        closeButton.toolTip = closeTitle
        closeButton.target = self
        closeButton.action = #selector(closePane)

        let row = NSStackView(views: [hostLabel, reloadButton, closeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space1
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let side = TitlebarBandButton.side
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space3),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.space1),
            reloadButton.widthAnchor.constraint(equalToConstant: side),
            reloadButton.heightAnchor.constraint(equalToConstant: side),
            closeButton.widthAnchor.constraint(equalToConstant: side),
            closeButton.heightAnchor.constraint(equalToConstant: side),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public func showHost(_ host: String) {
        // Keep a provider's address left-to-right in every Settings language.
        hostLabel.stringValue = host.isEmpty ? "" : "\u{2066}\(host)\u{2069}"
        hostLabel.toolTip = host.isEmpty ? nil : host
    }

    @objc private func reloadPage() { reload() }
    @objc private func closePane() { close() }
}
