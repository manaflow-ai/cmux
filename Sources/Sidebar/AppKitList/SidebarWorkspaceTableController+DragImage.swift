import AppKit
import CmuxSettings

extension SidebarWorkspaceTableController {
    func workspaceDragImage(
        tableView: NSTableView,
        row: Int,
        size: NSSize,
        count: Int,
        chromePalette: ChromePalette
    ) -> NSImage? {
        let rowRect = tableView.rect(ofRow: row)
        guard rowRect.width > 0,
              rowRect.height > 0,
              size.width > 0,
              size.height > 0,
              let representation = tableView.bitmapImageRepForCachingDisplay(in: rowRect) else {
            return nil
        }
        tableView.cacheDisplay(in: rowRect, to: representation)
        let rowImage = NSImage(size: rowRect.size)
        rowImage.addRepresentation(representation)

        return NSImage(size: size, flipped: false) { bounds in
            rowImage.draw(in: bounds)

            let badgeDiameter: CGFloat = 18
            let badgeInset: CGFloat = 2
            let badgeRect = NSRect(
                x: bounds.maxX - badgeDiameter - badgeInset,
                y: bounds.maxY - badgeDiameter - badgeInset,
                width: badgeDiameter,
                height: badgeDiameter
            )
            (chromePalette[.accent]).cmuxNSColor.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            let countText = "\(count)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: (chromePalette.textOnAccent).cmuxNSColor,
            ]
            let textSize = countText.size(withAttributes: attributes)
            countText.draw(
                at: NSPoint(
                    x: badgeRect.midX - (textSize.width / 2),
                    y: badgeRect.midY - (textSize.height / 2)
                ),
                withAttributes: attributes
            )
            return true
        }
    }
}
