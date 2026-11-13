// SPDX-License-Identifier: GPL-3.0-or-later
public import AppKit
public import AVFoundation
public import CmuxNextComputerUse
import CmuxNextDesign

/// The live preview over one agent surface (a terminal pane or an agent chat): a layer the size of
/// the surface that takes clicks only on what it shows (the thumbnail, the chip, the expanded view)
/// and passes every other click to the surface under it. The controller decides what it shows;
/// this view only lays it out.
@MainActor
public final class ComputerUsePreviewOverlay: NSView {
    public var onRequest: (ComputerUsePreviewRequest) -> Void = { _ in }

    public let thumbnail = ComputerUsePreviewThumbnail()
    private let expanded = ComputerUsePreviewExpanded()
    private lazy var chip = ComputerUsePreviewChip { [weak self] in self?.onRequest(.show) }
    public private(set) var presentation = ComputerUsePreviewPresentation.card
    /// The picture's aspect (width / height), from the stream.
    public var aspect: CGFloat = 16.0 / 10.0 {
        didSet {
            thumbnail.aspect = aspect
            expanded.aspect = aspect
            needsLayout = true
        }
    }
    private weak var video: AVSampleBufferDisplayLayer?
    private var entered = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        thumbnail.onRequest = { [weak self] in self?.onRequest($0) }
        expanded.onClose = { [weak self] in self?.onRequest(.collapse) }
        addSubview(thumbnail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var acceptsFirstResponder: Bool { false }

    /// Clicks go to what the overlay shows; the rest of the surface keeps its own.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// The stream whose video this overlay shows.
    public func show(video layer: AVSampleBufferDisplayLayer) {
        video = layer
        place(video: layer)
    }

    /// A still in place of the video (nil: the video).
    public func show(still data: Data?) { thumbnail.show(still: data) }

    /// Shows `presentation`: the thumbnail, the expanded view or the chip.
    public func present(_ presentation: ComputerUsePreviewPresentation) {
        guard presentation != self.presentation || !entered else { return }
        let first = !entered
        entered = true
        self.presentation = presentation
        expanded.removeFromSuperview()
        chip.removeFromSuperview()
        switch presentation {
        case .card:
            thumbnail.isHidden = false
            if first { thumbnail.playEntrance() }
        case .expanded:
            thumbnail.isHidden = false
            expanded.frame = bounds
            addSubview(expanded)
            Motion.overlays.animate(.fadeIn, in: expanded, { expanded.animator().alphaValue = 1 })
        case .hidden:
            thumbnail.isHidden = true
            addSubview(chip)
        }
        if let video { place(video: video) }
        needsLayout = true
    }

    /// Whether `point` (window coordinates) is over the expanded view's picture.
    public func expandedPictureContains(windowPoint point: NSPoint) -> Bool {
        guard presentation == .expanded, expanded.superview === self else { return false }
        return expanded.pictureFrame.contains(expanded.convert(point, from: nil))
    }

    /// The thumbnail's corner and long side (the person's drag and resize).
    public func place(corner: ComputerUsePreviewLayout.Corner, longSide: CGFloat) {
        thumbnail.corner = corner
        thumbnail.longSide = longSide
        needsLayout = true
    }

    /// The agent finished or stopped: the completion effect, then `done`.
    public func complete(_ done: @escaping @MainActor @Sendable () -> Void) {
        expanded.removeFromSuperview()
        guard !thumbnail.isHidden else { return done() }
        thumbnail.playCompletion(done)
    }

    private func place(video layer: AVSampleBufferDisplayLayer) {
        if presentation == .expanded {
            thumbnail.attach(video: nil)
            expanded.attach(video: layer)
        } else {
            expanded.attach(video: nil)
            thumbnail.attach(video: layer)
        }
    }

    public override func layout() {
        super.layout()
        expanded.frame = bounds
        let layout = ComputerUsePreviewLayout(corner: thumbnail.corner, longSide: thumbnail.longSide, aspect: aspect)
        if !thumbnail.isDragging {
            thumbnail.frame = layout.thumbnailFrame(in: bounds.size)
        }
        chip.frame = layout.chipFrame(size: chip.fittingSize, in: bounds.size)
    }
}
