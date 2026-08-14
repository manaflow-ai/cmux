import AppKit
import CmuxSettings

/// A small non-activating panel that advertises the suffixes available after
/// the configured cmux prefix is pressed.
@MainActor
final class ShortcutPrefixHUD {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(bindings: [ShortcutPrefixChordBinding], anchorWindow: NSWindow?) {
        let formatter = ShortcutDisplayFormatter()
        let suffixes = bindings.map { binding in
            let suffix = binding.secondStroke
            if binding.matchesNumberedDigits, let digit = Int(suffix.key), (1...9).contains(digit) {
                return formatter.modifierDisplayString(suffix) + formatter.numberedDigitRangeHint
            }
            return formatter.displayString(suffix)
        }
        guard !suffixes.isEmpty else {
            hide()
            return
        }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        label.stringValue = String.localizedStringWithFormat(
            String(localized: "shortcut.prefix.hud.available", defaultValue: "Prefix armed · %@"),
            suffixes.joined(separator: "  ")
        )
        label.sizeToFit()
        let width = min(max(label.fittingSize.width + 24, 180), 560)
        let height: CGFloat = 30
        let anchor = anchorWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: anchor.midX - width / 2,
            y: anchor.minY + 42
        )
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        label.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.drawsBackground = true
        label.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92)
        label.wantsLayer = true
        label.layer?.cornerRadius = 8
        label.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        label.layer?.borderWidth = 1
        label.frame = panel.contentView?.bounds ?? .zero
        label.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(label)
        return panel
    }
}
