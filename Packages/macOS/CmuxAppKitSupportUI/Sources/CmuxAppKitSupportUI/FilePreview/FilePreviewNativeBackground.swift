public import AppKit

/// Pure AppKit helpers that paint the file-preview native host's background layer and
/// scroll/clip view backgrounds. Stateless; operates on the views it is handed.
public enum FilePreviewNativeBackground {
    /// The effective background color, or `.clear` when the host does not draw a background.
    public static func resolvedColor(backgroundColor: NSColor, drawsBackground: Bool) -> NSColor {
        drawsBackground ? backgroundColor : .clear
    }

    /// Sets the view's backing layer color and opacity from the resolved background.
    public static func applyRootLayer(
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

    /// Recursively applies the resolved background to every scroll/clip view in the hierarchy.
    public static func applyScrollBackgrounds(
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

    /// Identifiers of every scroll/clip view in the hierarchy, used to detect background hosts.
    public static func scrollBackgroundHostIdentifiers(in view: NSView) -> Set<ObjectIdentifier> {
        var identifiers = Set<ObjectIdentifier>()
        collectScrollBackgroundHostIdentifiers(in: view, into: &identifiers)
        return identifiers
    }

    private static func collectScrollBackgroundHostIdentifiers(
        in view: NSView,
        into identifiers: inout Set<ObjectIdentifier>
    ) {
        if view is NSScrollView || view is NSClipView {
            identifiers.insert(ObjectIdentifier(view))
        }
        for subview in view.subviews {
            collectScrollBackgroundHostIdentifiers(in: subview, into: &identifiers)
        }
    }
}
