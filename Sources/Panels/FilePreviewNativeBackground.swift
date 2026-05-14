import AppKit

enum FilePreviewNativeBackground {
    static func resolvedColor(backgroundColor: NSColor, drawsBackground: Bool) -> NSColor {
        drawsBackground ? backgroundColor : .clear
    }

    static func applyRootLayer(
        to view: NSView,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        let resolvedBackgroundColor = resolvedColor(
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
        view.wantsLayer = true
        view.layer?.backgroundColor = resolvedBackgroundColor.cgColor
        view.layer?.isOpaque = drawsBackground && resolvedBackgroundColor.alphaComponent >= 0.999
    }

    static func applyScrollBackgrounds(
        in view: NSView,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        let resolvedBackgroundColor = resolvedColor(
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
        if let scrollView = view as? NSScrollView {
            scrollView.drawsBackground = drawsBackground
            scrollView.backgroundColor = resolvedBackgroundColor
        }
        if let clipView = view as? NSClipView {
            clipView.drawsBackground = drawsBackground
            clipView.backgroundColor = resolvedBackgroundColor
        }
        for subview in view.subviews {
            applyScrollBackgrounds(
                in: subview,
                backgroundColor: backgroundColor,
                drawsBackground: drawsBackground
            )
        }
    }
}
