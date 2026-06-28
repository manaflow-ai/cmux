public import CoreGraphics
import Foundation

/// Pure signature + log-line assembly for a terminal surface's drop-zone
/// overlay debug trace.
///
/// This is the terminal-domain home of the string building that lived inside
/// the `#if DEBUG` `GhosttyNSView.logDropZoneOverlay`. The witness keeps the
/// live AppKit reads (the surface id prefix, the `String(describing:)` zone
/// text, the overlay superview class via `type(of:)`, the overlay `isHidden`
/// flag, and the `superview === self` external check) and the `cmuxDebugLog`
/// emission plus the `lastDropZoneOverlayLogSignature` de-duplication. It
/// resolves those AppKit-derived values once and hands them here; this builder
/// performs the deterministic `String(format:)` geometry formatting and
/// assembles both the de-dup `signature` and the `logMessage`, so the string
/// assembly stays a pure value computation that references no AppKit.
public struct TerminalDropOverlayLogSignature: Sendable {
    /// The event name (e.g. `"hideComplete"`).
    public let event: String
    /// The terminal surface id prefix, or a placeholder when there is no surface.
    public let surface: String
    /// The active drop zone described, or `"none"` when there is no zone.
    public let zoneText: String
    /// The view's live bounds (only `width`/`height` are formatted).
    public let bounds: CGRect
    /// The overlay's target frame, or `nil` to render as `"-"`.
    public let frame: CGRect?
    /// The class name of the overlay's superview, or a placeholder when detached.
    public let overlaySuperviewClass: String
    /// The scroll content view's bounds origin.
    public let scrollOrigin: CGPoint
    /// The surface view's frame origin.
    public let surfaceOrigin: CGPoint
    /// The overlay's live `isHidden` flag.
    public let isHidden: Bool
    /// Whether the overlay is reparented outside the view (`superview !== self`).
    public let overlayExternal: Bool

    /// Seeds the builder with the AppKit-derived values resolved by the witness.
    public init(
        event: String,
        surface: String,
        zoneText: String,
        bounds: CGRect,
        frame: CGRect?,
        overlaySuperviewClass: String,
        scrollOrigin: CGPoint,
        surfaceOrigin: CGPoint,
        isHidden: Bool,
        overlayExternal: Bool
    ) {
        self.event = event
        self.surface = surface
        self.zoneText = zoneText
        self.bounds = bounds
        self.frame = frame
        self.overlaySuperviewClass = overlaySuperviewClass
        self.scrollOrigin = scrollOrigin
        self.surfaceOrigin = surfaceOrigin
        self.isHidden = isHidden
        self.overlayExternal = overlayExternal
    }

    /// `"<width>x<height>"` to one decimal place.
    public var boundsText: String {
        String(format: "%.1fx%.1f", bounds.width, bounds.height)
    }

    /// `"<x>,<y>"` for the scroll origin, to one decimal place.
    public var scrollOriginText: String {
        String(format: "%.1f,%.1f", scrollOrigin.x, scrollOrigin.y)
    }

    /// `"<x>,<y>"` for the surface origin, to one decimal place.
    public var surfaceOriginText: String {
        String(format: "%.1f,%.1f", surfaceOrigin.x, surfaceOrigin.y)
    }

    /// `"<x>,<y> <width>x<height>"` for the target frame, or `"-"` when absent.
    public var frameText: String {
        guard let frame else { return "-" }
        return String(
            format: "%.1f,%.1f %.1fx%.1f",
            frame.origin.x, frame.origin.y, frame.width, frame.height
        )
    }

    /// The pipe-delimited de-duplication signature.
    public var signature: String {
        "\(event)|\(surface)|\(zoneText)|\(boundsText)|\(frameText)|\(overlaySuperviewClass)|" +
        "\(scrollOriginText)|\(surfaceOriginText)|\(isHidden ? 1 : 0)"
    }

    /// The `cmuxDebugLog` line emitted when the signature changes.
    public var logMessage: String {
        "terminal.dropOverlay event=\(event) surface=\(surface) zone=\(zoneText) " +
        "hidden=\(isHidden ? 1 : 0) bounds=\(boundsText) frame=\(frameText) " +
        "overlaySuper=\(overlaySuperviewClass) overlayExternal=\(overlayExternal ? 1 : 0) " +
        "scrollOrigin=\(scrollOriginText) surfaceOrigin=\(surfaceOriginText)"
    }
}
