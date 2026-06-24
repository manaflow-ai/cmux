public import AppKit

/// File-preview background painting, homed on the AppKit types it operates on.
///
/// Replaces the former caseless `FilePreviewNativeBackground` namespace enum: the
/// background-color resolution lives on `NSColor` (the value it produces), and
/// the layer/scroll-view painting lives on `NSView` (the view it mutates), per
/// the no-namespace-enum convention. The PDF and image preview surfaces share
/// these to paint a flat, possibly transparent backdrop behind their content.
extension NSColor {
    /// The flat backdrop color a file-preview surface should paint: the requested
    /// background when drawing is enabled, otherwise `.clear` so the host shows
    /// through.
    public static func filePreviewResolvedBackground(
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) -> NSColor {
        drawsBackground ? backgroundColor : .clear
    }
}

extension NSView {
    /// Paints this view's backing layer with the resolved file-preview backdrop,
    /// marking the layer opaque only when fully opaque drawing is requested.
    public func applyFilePreviewRootLayerBackground(
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        let resolvedBackgroundColor = NSColor.filePreviewResolvedBackground(
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
        wantsLayer = true
        layer?.backgroundColor = resolvedBackgroundColor.cgColor
        layer?.isOpaque = drawsBackground && resolvedBackgroundColor.alphaComponent >= 0.999
    }

    /// Recursively paints every `NSScrollView`/`NSClipView` in this view's
    /// subtree with the resolved file-preview backdrop.
    public func applyFilePreviewScrollBackgrounds(
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        let resolvedBackgroundColor = NSColor.filePreviewResolvedBackground(
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
        if let scrollView = self as? NSScrollView {
            scrollView.drawsBackground = drawsBackground
            scrollView.backgroundColor = resolvedBackgroundColor
        }
        if let clipView = self as? NSClipView {
            clipView.drawsBackground = drawsBackground
            clipView.backgroundColor = resolvedBackgroundColor
        }
        for subview in subviews {
            subview.applyFilePreviewScrollBackgrounds(
                backgroundColor: backgroundColor,
                drawsBackground: drawsBackground
            )
        }
    }

    /// Object identifiers of every `NSScrollView`/`NSClipView` in this view's
    /// subtree, used to detect when the scroll-host set changed and the backdrop
    /// must be re-applied.
    public var filePreviewScrollBackgroundHostIdentifiers: Set<ObjectIdentifier> {
        var identifiers = Set<ObjectIdentifier>()
        collectFilePreviewScrollBackgroundHostIdentifiers(into: &identifiers)
        return identifiers
    }

    private func collectFilePreviewScrollBackgroundHostIdentifiers(
        into identifiers: inout Set<ObjectIdentifier>
    ) {
        if self is NSScrollView || self is NSClipView {
            identifiers.insert(ObjectIdentifier(self))
        }
        for subview in subviews {
            subview.collectFilePreviewScrollBackgroundHostIdentifiers(into: &identifiers)
        }
    }
}
