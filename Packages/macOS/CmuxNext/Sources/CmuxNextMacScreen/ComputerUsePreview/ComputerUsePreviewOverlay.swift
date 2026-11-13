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
    /// The still shown in place of the video, nil while the video shows.
    private var still: CGImage?
    private var entered = false
    /// The card's entrance played (the first time the overlay showed a picture).
    private var revealed = false

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

    /// A still in place of the video (nil: the video), in whichever view holds the picture.
    public func show(still image: CGImage?) {
        still = image
        placeStill()
    }

    /// The overlay shows from now on, with the card's entrance the first time: the presenter calls
    /// it once there is a picture (a frame or a still), so no empty card ever appears.
    public func reveal() {
        isHidden = false
        guard !revealed else { return }
        revealed = true
        if presentation == .card { thumbnail.playEntrance() }
    }

    /// The thumbnail and the expanded view show a still (tests).
    var showsStill: (thumbnail: Bool, expanded: Bool) { (thumbnail.showsStill, expanded.showsStill) }

    /// Shows `presentation`: the thumbnail, the expanded view or the chip. The card's entrance
    /// plays in ``reveal()``, once there is a picture.
    public func present(_ presentation: ComputerUsePreviewPresentation) {
        guard presentation != self.presentation || !entered else { return }
        entered = true
        let collapsing = self.presentation == .expanded && expanded.superview === self && presentation != .expanded
        self.presentation = presentation
        chip.removeFromSuperview()
        if collapsing { expanded.isClosing = true }
        switch presentation {
        case .card:
            // From the expanded view: the card shows, with the picture, once its fade ends.
            thumbnail.isHidden = expanded.isClosing
        case .expanded:
            // The large view takes the picture; the card under the scrim is hidden, not doubled.
            thumbnail.isHidden = true
            expanded.frame = bounds
            expanded.isClosing = false
            if expanded.superview !== self { addSubview(expanded) }
            expanded.alphaValue = 0 // every expand fades in
            Motion.overlays.animate(.fadeIn, in: expanded, { self.expanded.animator().alphaValue = 1 })
        case .hidden:
            thumbnail.isHidden = true
            addSubview(chip)
        }
        // While the expanded view fades out it keeps the picture (placement routes by isClosing).
        if let video { place(video: video) }
        placeStill()
        needsLayout = true
        // Last, after the switch and the placement: a fade that ends at once (the window cannot
        // animate) finishes the collapse here, and nothing above undoes it.
        if collapsing { fadeOutExpanded() }
    }

    /// The thumbnail's corner and long side (the person's drag and resize).
    public func place(corner: ComputerUsePreviewLayout.Corner, longSide: CGFloat) {
        thumbnail.corner = corner
        thumbnail.longSide = longSide
        needsLayout = true
    }

    /// The agent finished or stopped: the completion effect on whichever view shows (the card's
    /// pulse, or the expanded view fading out), then `done`.
    /// Not `complete(_:)`: NSResponder's `complete:` (text completion) shares that name, and a call
    /// whose closure is not `@Sendable` resolves to it and is sent to AppKit.
    public func playFinish(_ done: @escaping @MainActor @Sendable () -> Void) {
        guard !isHidden else { return done() }
        // Expanded, or fading out after a collapse: the expanded view holds the picture, and its
        // fade (to the end, from wherever it is) is the effect.
        if presentation == .expanded || expanded.isClosing, expanded.superview === self {
            return fadeOut(expanded, { self.expanded.animator().alphaValue = 0 }, done)
        }
        guard !thumbnail.isHidden else { return done() }
        thumbnail.playCompletion(done)
    }

    /// Collapsing: the expanded view fades out, then leaves (unless the person expanded again).
    /// It takes no click while it fades (the surface under it does), keeps the picture until the
    /// fade ends, and then hands the picture to the card.
    private func fadeOutExpanded() {
        fadeOut(expanded, { self.expanded.animator().alphaValue = 0 }, { [weak self] in
            guard let self, self.presentation != .expanded else { return }
            self.expanded.removeFromSuperview()
            self.expanded.isClosing = false
            self.finishCollapse()
        })
    }

    /// The collapse ended (isClosing is false now): the picture moves to the card, which shows
    /// unless hidden meanwhile.
    private func finishCollapse() {
        if let video { place(video: video) }
        placeStill()
        if presentation == .card { thumbnail.isHidden = false }
        collapseFinished?()
    }

    /// Runs a fade-out on `view` (``Motion/overlays``). It completes at once when the window cannot
    /// animate (minimized, ordered out, covered, its display asleep); tests make it do so.
    var fadeOut: (_ view: NSView, _ changes: () -> Void, _ completion: @escaping @MainActor @Sendable () -> Void) -> Void = {
        Motion.overlays.animate(.fadeOut, in: $0, $1, completion: $2)
    }

    /// Runs when a collapse's fade ended and the picture moved (tests wait on it).
    var collapseFinished: (() -> Void)?

    /// The expanded view is fading out and takes no clicks (tests).
    var expandedIsClosing: Bool { expanded.isClosing }

    /// The surface is an agent's terminal: Hide names the agent, not the chat.
    public var surfaceIsTerminal: Bool {
        get { thumbnail.surfaceIsTerminal }
        set { thumbnail.surfaceIsTerminal = newValue }
    }

    /// The expanded view holds the picture: it is expanded, or fading out after a collapse (a still
    /// that comes mid-fade stays on the view that shows, not on the card under it).
    private var expandedHoldsPicture: Bool { presentation == .expanded || expanded.isClosing }

    /// The still goes where the picture is.
    private func placeStill() {
        let expandedHolds = expandedHoldsPicture
        expanded.show(still: expandedHolds ? still : nil)
        thumbnail.show(still: expandedHolds ? nil : still)
    }

    private func place(video layer: AVSampleBufferDisplayLayer) {
        if expandedHoldsPicture {
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
