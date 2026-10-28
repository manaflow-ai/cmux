public import AppKit

extension NSMenuItem {
    /// Shows `subtitle` under the title: the system `subtitle` on macOS 14.4 and later; below it
    /// (macOS 14.0-14.3) the same text as a second, smaller line in secondary color of the
    /// attributed title, so the row still shows its status (plans/cmux-next/macos-floor.md).
    @MainActor
    public func showSubtitle(_ subtitle: String?) {
        if #available(macOS 14.4, *) {
            self.subtitle = subtitle
            return
        }
        guard let subtitle, !subtitle.isEmpty else {
            attributedTitle = nil
            return
        }
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        text.append(NSAttributedString(string: "\n" + subtitle, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        attributedTitle = text
    }
}
