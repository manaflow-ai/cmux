import AppKit
import CmuxTerminal

/// A small pane-local diagnostic shown when the terminal has a live model but
/// no renderer presentation, or when its child process has exited.
final class TerminalRenderHealthOverlayView: NSView {
    private let cardView = NSVisualEffectView(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]

        cardView.material = .hudWindow
        cardView.blendingMode = .withinWindow
        cardView.state = .active
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 8
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        addSubview(cardView)

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 15,
            weight: .semibold
        )
        iconView.contentTintColor = .secondaryLabelColor
        cardView.addSubview(iconView)

        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        cardView.addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func apply(_ health: TerminalSurfaceRenderHealth) {
        switch health {
        case .notRendering:
            iconView.image = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: nil
            )
            label.stringValue = String(
                localized: "terminal.renderHealth.notRendering",
                defaultValue: "Terminal is not rendering"
            )
            isHidden = false
        case .shellExited:
            iconView.image = NSImage(
                systemSymbolName: "xmark.circle",
                accessibilityDescription: nil
            )
            label.stringValue = String(
                localized: "terminal.renderHealth.shellExited",
                defaultValue: "Shell exited"
            )
            isHidden = false
        case .notStarted, .awaitingFrame, .rendering:
            isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let cardWidth = min(max(180, bounds.width - 32), 300)
        let cardHeight: CGFloat = 32
        cardView.frame = NSRect(
            x: floor((bounds.width - cardWidth) / 2),
            y: floor((bounds.height - cardHeight) / 2),
            width: cardWidth,
            height: cardHeight
        )
        iconView.frame = NSRect(x: 10, y: 8, width: 16, height: 16)
        label.frame = NSRect(x: 30, y: 6, width: cardWidth - 40, height: 20)
    }
}
