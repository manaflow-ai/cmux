import AppKit
import CmuxAcpmux

/// Prompts queued behind the running turn, with "Send now" and remove actions.
@MainActor
final class AcpmuxQueueStripView: AcpmuxFlippedView {
    private var rowsViews: [NSView] = []
    private(set) var entries: [AcpmuxQueueEntry] = []
    var onSteer: ((AcpmuxQueueEntry) -> Void)?
    var onRemove: ((AcpmuxQueueEntry) -> Void)?
    static let rowHeight: CGFloat = 24

    func update(_ entries: [AcpmuxQueueEntry], theme: AcpmuxChatTheme) {
        guard entries != self.entries else { return }
        self.entries = entries
        rowsViews.forEach { $0.removeFromSuperview() }
        rowsViews = entries.prefix(3).enumerated().map { index, entry in
            let row = AcpmuxFlippedView(frame: .zero)
            row.layer?.cornerRadius = 8
            row.layer?.backgroundColor = theme.surface.cgColor
            let label = NSTextField(labelWithString: "")
            let prefix = String(localized: "acpmuxChat.queue.label", defaultValue: "Queued")
            label.attributedStringValue = NSAttributedString(string: "\(prefix)  \(entry.text ?? "")", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: theme.secondaryText,
            ])
            label.lineBreakMode = .byTruncatingTail
            label.tag = 1
            row.addSubview(label)
            let steer = NSButton(
                title: String(localized: "acpmuxChat.queue.sendNow", defaultValue: "Send now"),
                target: self,
                action: #selector(steerPressed(_:))
            )
            steer.bezelStyle = .inline
            steer.controlSize = .mini
            steer.tag = index
            row.addSubview(steer)
            let remove = NSButton(
                image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "acpmuxChat.queue.remove", defaultValue: "Remove"))!,
                target: self,
                action: #selector(removePressed(_:))
            )
            remove.isBordered = false
            remove.tag = index
            remove.contentTintColor = theme.tertiaryText
            row.addSubview(remove)
            addSubview(row)
            return row
        }
        needsLayout = true
    }

    var preferredHeight: CGFloat {
        CGFloat(min(entries.count, 3)) * (Self.rowHeight + 4)
    }

    override func layout() {
        super.layout()
        for (index, row) in rowsViews.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(index) * (Self.rowHeight + 4), width: bounds.width, height: Self.rowHeight)
            let buttons = row.subviews.compactMap { $0 as? NSButton }
            var x = row.bounds.width - 8
            for button in buttons.reversed() {
                button.sizeToFit()
                x -= button.frame.width
                button.frame.origin = CGPoint(x: x, y: (Self.rowHeight - button.frame.height) / 2)
                x -= 6
            }
            if let label = row.subviews.first(where: { $0.tag == 1 }) {
                label.frame = CGRect(x: 10, y: 4, width: max(0, x - 14), height: 16)
            }
        }
    }

    @objc private func steerPressed(_ sender: NSButton) {
        guard sender.tag < entries.count else { return }
        onSteer?(entries[sender.tag])
    }

    @objc private func removePressed(_ sender: NSButton) {
        guard sender.tag < entries.count else { return }
        onRemove?(entries[sender.tag])
    }
}
