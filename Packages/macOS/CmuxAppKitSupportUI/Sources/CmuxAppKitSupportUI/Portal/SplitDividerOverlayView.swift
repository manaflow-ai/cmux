public import AppKit

/// Paints native `NSSplitView` divider lines on top of portal-hosted terminal
/// surfaces. The portal reparents terminal views above the split hierarchy, which
/// can hide a split view's own divider behind a hosted surface; this overlay walks
/// the window's `contentView` for every split divider and redraws the ones a hosted
/// surface intrudes across, matching each split view's native divider color.
///
/// It never becomes first responder and never hit-tests, so it overlays content
/// without intercepting events.
///
/// The set of hosted-surface frames that can occlude a divider is resolved app-side
/// (the hosted surface type lives in the app target), so the app injects it through
/// ``occludingHostedFramesProvider`` rather than this package depending on that type.
public final class SplitDividerOverlayView: NSView {
    private struct DividerSegment {
        let rect: NSRect
        let color: NSColor
        let isVertical: Bool
    }

    /// Resolves the frames of hosted surfaces that can occlude split dividers,
    /// given the overlay's host superview. Injected by the app (which owns the
    /// hosted-surface view type) so this view stays decoupled from app-side
    /// terminal state. The default resolves to no occluding frames.
    public var occludingHostedFramesProvider: @MainActor (NSView) -> [NSRect] = { _ in [] }

    public override var isOpaque: Bool { false }
    public override var acceptsFirstResponder: Bool { false }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let window, let rootView = window.contentView else { return }

        var dividerSegments: [DividerSegment] = []
        collectDividerSegments(in: rootView, into: &dividerSegments)
        guard !dividerSegments.isEmpty else { return }
        let hostedFrames = hostedFramesLikelyToOccludeDividers()
        let visibleSegments = dividerSegments.filter { shouldRenderOverlay(for: $0, hostedFrames: hostedFrames) }
        guard !visibleSegments.isEmpty else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Keep separators visible above portal-hosted surfaces while matching each split view's
        // native divider color (avoids visible color shifts at tiny pane sizes).
        for segment in visibleSegments where segment.rect.intersects(dirtyRect) {
            segment.color.setFill()
            let rect = segment.rect
            let pixelAligned = NSRect(
                x: floor(rect.origin.x),
                y: floor(rect.origin.y),
                width: max(1, round(rect.size.width)),
                height: max(1, round(rect.size.height))
            )
            NSBezierPath(rect: pixelAligned).fill()
        }
    }

    private func collectDividerSegments(in view: NSView, into result: inout [DividerSegment]) {
        guard !view.isHidden else { return }

        if let splitView = view as? NSSplitView {
            let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
            let dividerColor = overlayDividerColor(for: splitView)
            for dividerIndex in 0..<dividerCount {
                let first = splitView.arrangedSubviews[dividerIndex].frame
                let thickness = max(splitView.dividerThickness, 1)
                let dividerRectInSplit: NSRect
                if splitView.isVertical {
                    dividerRectInSplit = NSRect(
                        x: first.maxX,
                        y: 0,
                        width: thickness,
                        height: splitView.bounds.height
                    )
                } else {
                    dividerRectInSplit = NSRect(
                        x: 0,
                        y: first.maxY,
                        width: splitView.bounds.width,
                        height: thickness
                    )
                }

                let dividerRectInWindow = splitView.convert(dividerRectInSplit, to: nil)
                let dividerRectInOverlay = convert(dividerRectInWindow, from: nil)
                if dividerRectInOverlay.intersects(bounds) {
                    result.append(
                        DividerSegment(
                            rect: dividerRectInOverlay,
                            color: dividerColor,
                            isVertical: splitView.isVertical
                        )
                    )
                }
            }
        }

        for subview in view.subviews {
            collectDividerSegments(in: subview, into: &result)
        }
    }

    private func hostedFramesLikelyToOccludeDividers() -> [NSRect] {
        guard let hostView = superview else { return [] }
        return occludingHostedFramesProvider(hostView)
    }

    private func shouldRenderOverlay(for segment: DividerSegment, hostedFrames: [NSRect]) -> Bool {
        // Draw only when a hosted surface actually intrudes across the divider centerline.
        // This preserves tiny-pane visibility fixes without darkening regular dividers.
        let axisEpsilon: CGFloat = 0.01
        let axis = segment.isVertical ? segment.rect.midX : segment.rect.midY
        let extentRect = segment.rect.insetBy(
            dx: segment.isVertical ? 0 : -1,
            dy: segment.isVertical ? -1 : 0
        )

        for frame in hostedFrames where frame.intersects(extentRect) {
            if segment.isVertical {
                if frame.minX < axis - axisEpsilon && frame.maxX > axis + axisEpsilon {
                    return true
                }
            } else if frame.minY < axis - axisEpsilon && frame.maxY > axis + axisEpsilon {
                return true
            }
        }
        return false
    }

    private func overlayDividerColor(for splitView: NSSplitView) -> NSColor {
        let divider = splitView.dividerColor.usingColorSpace(.deviceRGB) ?? splitView.dividerColor
        let alpha = divider.alphaComponent
        guard alpha < 0.999 else { return divider }

        guard let bgColor = splitView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
              let bgRGB = bgColor.usingColorSpace(.deviceRGB) else {
            return divider
        }

        let opaqueBG = bgRGB.withAlphaComponent(1)
        let opaqueDivider = divider.withAlphaComponent(1)
        return opaqueBG.blended(withFraction: alpha, of: opaqueDivider) ?? divider
    }
}
