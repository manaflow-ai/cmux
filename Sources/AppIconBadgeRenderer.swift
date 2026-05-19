import AppKit

enum AppIconBadgeRenderer {
    static func normalizedBadgeLabel(_ rawLabel: String?) -> String? {
        guard let label = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            return nil
        }
        return label
    }

    @MainActor
    static func image(baseIcon: NSImage, badgeLabel rawBadgeLabel: String?) -> NSImage {
        guard let badgeLabel = normalizedBadgeLabel(rawBadgeLabel) else {
            return baseIcon
        }

        let size = normalizedIconSize(baseIcon.size)
        let result = NSImage(size: size)
        result.isTemplate = false
        result.lockFocus()
        defer { result.unlockFocus() }

        baseIcon.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: baseIcon.size),
            operation: .sourceOver,
            fraction: 1
        )
        drawBadge(badgeLabel, in: NSRect(origin: .zero, size: size))
        return result
    }

    @MainActor
    private static func normalizedIconSize(_ size: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else {
            return NSSize(width: 128, height: 128)
        }
        return size
    }

    @MainActor
    private static func drawBadge(_ label: String, in bounds: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        NSGraphicsContext.current?.shouldAntialias = true

        let iconEdge = min(bounds.width, bounds.height)
        let badgeHeight = max(18, iconEdge * 0.34)
        let horizontalPadding = badgeHeight * 0.28
        let maxBadgeWidth = bounds.width * 0.86
        let font = badgeFont(
            fitting: label,
            badgeHeight: badgeHeight,
            horizontalPadding: horizontalPadding,
            maxBadgeWidth: maxBadgeWidth
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = label.size(withAttributes: attributes)
        let badgeWidth = min(maxBadgeWidth, max(badgeHeight, ceil(textSize.width + horizontalPadding * 2)))
        let badgeRect = NSRect(
            x: bounds.maxX - badgeWidth - iconEdge * 0.02,
            y: bounds.maxY - badgeHeight - iconEdge * 0.02,
            width: badgeWidth,
            height: badgeHeight
        )

        NSColor(calibratedRed: 1.0, green: 0.12, blue: 0.16, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()

        let textRect = NSRect(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        label.draw(in: textRect, withAttributes: attributes)
    }

    @MainActor
    private static func badgeFont(
        fitting label: String,
        badgeHeight: CGFloat,
        horizontalPadding: CGFloat,
        maxBadgeWidth: CGFloat
    ) -> NSFont {
        let baseSize = max(11, badgeHeight * 0.56)
        let baseFont = NSFont.systemFont(ofSize: baseSize, weight: .bold)
        let textWidth = label.size(withAttributes: [.font: baseFont]).width
        let availableWidth = max(1, maxBadgeWidth - horizontalPadding * 2)
        guard textWidth > availableWidth else {
            return baseFont
        }
        return NSFont.systemFont(
            ofSize: max(8, floor(baseSize * availableWidth / max(textWidth, 1))),
            weight: .bold
        )
    }
}
