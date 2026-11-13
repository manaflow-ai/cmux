// SPDX-License-Identifier: GPL-3.0-or-later
public import AppKit
public import AVFoundation
import QuartzCore

/// The geometry of the live preview's thumbnail, as the ChatGPT app docks its Computer Use
/// picture: at the top right of the agent's surface, the window's own aspect, its long side at
/// ``defaultLongSide`` (the person resizes it up to ``maximumLongSide``), the window's own corners
/// scaled down, no border, a very soft shadow. Pure: tests read it.
public nonisolated struct ComputerUsePreviewLayout: Equatable, Sendable {
    /// Below the surface's content top.
    public static let topInset: CGFloat = 24.5
    /// From the surface's side edge.
    public static let sideInset: CGFloat = 20.5
    public static let defaultLongSide: CGFloat = 200
    public static let minimumLongSide: CGFloat = 120
    public static let maximumLongSide: CGFloat = 400
    /// The window's corner radius scaled down to the thumbnail.
    public static let cornerRadius: CGFloat = 4.5
    /// The entrance: from this scale and blur, as ChatGPT's preview appears.
    public static let entranceScale: CGFloat = 0.72
    public static let entranceBlur: CGFloat = 18
    /// The expanded view's share of its surface.
    public static let expandedShare: CGFloat = 0.86

    /// A corner of the surface the thumbnail docks in (a drag snaps it to the nearest).
    public enum Corner: String, CaseIterable, Sendable {
        case topRight, topLeft, bottomRight, bottomLeft

        /// The corner nearest `point` in a surface of `size` (AppKit coordinates, origin bottom left).
        public static func nearest(to point: CGPoint, in size: CGSize) -> Corner {
            let right = point.x >= size.width / 2
            let top = point.y >= size.height / 2
            switch (top, right) {
            case (true, true): return .topRight
            case (true, false): return .topLeft
            case (false, true): return .bottomRight
            case (false, false): return .bottomLeft
            }
        }
    }

    /// The corner the thumbnail docks in.
    public var corner: Corner
    /// The thumbnail's long side before it shrinks to fit (the person's resize).
    public var longSide: CGFloat
    /// The picture's aspect (width / height).
    public var aspect: CGFloat

    public init(corner: Corner = .topRight, longSide: CGFloat = Self.defaultLongSide, aspect: CGFloat = 16.0 / 10.0) {
        self.corner = corner
        self.longSide = longSide
        self.aspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 10.0
    }

    /// The thumbnail's size: its long side ``longSide`` (within the allowed range), shrunk to fit a
    /// surface `available` wide less both insets.
    public func thumbnailSize(available: CGFloat) -> CGSize {
        let room = max(Self.minimumLongSide / 2, available - 2 * Self.sideInset)
        let side = min(max(longSide, Self.minimumLongSide), Self.maximumLongSide)
        var size = aspect >= 1 ? CGSize(width: side, height: side / aspect) : CGSize(width: side * aspect, height: side)
        if size.width > room { size = CGSize(width: room, height: room / aspect) }
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    /// The thumbnail's frame in a surface of `bounds` (AppKit coordinates, origin bottom left),
    /// docked in ``corner``: ``topInset`` below the top, ``sideInset`` from the side.
    public func thumbnailFrame(in bounds: CGSize) -> CGRect {
        let size = thumbnailSize(available: bounds.width)
        let left = Self.sideInset, right = bounds.width - Self.sideInset - size.width
        let top = bounds.height - Self.topInset - size.height, bottom = Self.sideInset
        let origin: CGPoint
        switch corner {
        case .topRight: origin = CGPoint(x: right, y: top)
        case .topLeft: origin = CGPoint(x: left, y: top)
        case .bottomRight: origin = CGPoint(x: right, y: bottom)
        case .bottomLeft: origin = CGPoint(x: left, y: bottom)
        }
        return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }

    /// The restore chip's frame: always at the top right, where the thumbnail docks first.
    public func chipFrame(size: CGSize, in bounds: CGSize) -> CGRect {
        CGRect(x: bounds.width - Self.sideInset - size.width, y: bounds.height - Self.topInset - size.height,
               width: size.width, height: size.height)
    }

    /// The expanded view's size: the picture's aspect, at most ``expandedShare`` of `bounds`.
    public func expandedSize(in bounds: CGSize) -> CGSize {
        let width = bounds.width * Self.expandedShare, height = bounds.height * Self.expandedShare
        let size = width / height > aspect ? CGSize(width: height * aspect, height: height) : CGSize(width: width, height: width / aspect)
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }
}

/// What the person asks of a preview from its controls.
public enum ComputerUsePreviewRequest: Sendable, Equatable {
    case expand
    case collapse
    case showWindow
    case hideHere
    case hideEverywhere
    case show
    case moved(ComputerUsePreviewLayout.Corner)
    /// The grip moves: the card takes this long side now; the stream follows on ``resized(_:)``.
    case resizing(CGFloat)
    /// The resize ended at this long side.
    case resized(CGFloat)
}

/// The picture of a preview: the stream's video under a still that stands in for it, both filling
/// the view, its corners clipped. The thumbnail and the expanded view each hold one, and the overlay
/// moves the video and the still to whichever shows.
@MainActor
public final class ComputerUsePreviewPictureView: NSView {
    private let still = CALayer()
    private weak var video: AVSampleBufferDisplayLayer?

    public init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        still.contentsGravity = .resizeAspect
        layer?.addSublayer(still)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var acceptsFirstResponder: Bool { false }

    /// Shows `layer` (the stream's video); nil takes it out (the other view has it).
    public func attach(video layer: AVSampleBufferDisplayLayer?) {
        if let video, video.superlayer === self.layer { video.removeFromSuperlayer() }
        video = layer
        if let layer { self.layer?.insertSublayer(layer, below: still) }
        needsLayout = true
    }

    /// Shows a still in place of the video (nil: the video shows).
    public func show(still image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.contents = image
        CATransaction.commit()
    }

    /// A still is shown (tests).
    var showsStill: Bool { still.contents != nil }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video?.frame = bounds
        still.frame = bounds
        CATransaction.commit()
    }
}
