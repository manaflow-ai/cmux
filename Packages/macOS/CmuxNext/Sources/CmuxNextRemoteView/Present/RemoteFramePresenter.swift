public import AppKit
public import CmuxNextDesign

/// Presenter prototypes (`remoteDesktop.debug.presenter`, DEV and NIGHTLY
/// Debug Settings; section 7). Lawrence picks after the lit-display bench.
public nonisolated enum RemotePresenterKind: String, Sendable, CaseIterable, TunableChoice {
    /// A: the decoded IOSurface drawn and presented on the render queue, off
    /// main (p03-rendering-114). Main hears only of size changes.
    case layerContents
    /// B: `CAMetalLayer` with two drawables, a YUV shader, latest frame wins.
    case metal
    /// C: `AVSampleBufferDisplayLayer` with display-immediately samples.
    case sampleBuffer

    public var tunableTitle: String {
        switch self {
        case .layerContents: "A: IOSurface, presented off main"
        case .metal: "B: Metal layer (YUV shader)"
        case .sampleBuffer: "C: Sample buffer display layer"
        }
    }
}

/// Shows decoded frames in one layer. `present` is called off the main
/// actor by the decode pipeline, for every frame; the presenter keeps only
/// the newest undisplayed one (`LatestFrameMailbox`) and draws it with no
/// display link: the frame's arrival is the only wakeup.
@MainActor
public protocol RemoteFramePresenter: AnyObject, Sendable {
    var kind: RemotePresenterKind { get }
    /// The layer the pane positions at the image rect (1:1 pixels).
    var layer: CALayer { get }
    /// Called on the main actor when the decoded frame size changes.
    var onFrameSize: ((CGSize) -> Void)? { get set }
    /// Called on the main actor after a frame went on screen (`shownFrame` is it): after each frame,
    /// or, for a presenter that presents off main (A), only for the first frame after
    /// `armFrameShown()` and for a new frame size.
    var onFrameShown: (() -> Void)? { get set }
    /// The pane starts (again) and waits for its first frame: the next shown frame calls
    /// `onFrameShown`.
    func armFrameShown()
    nonisolated func present(_ frame: RemoteDecodedFrame)
    /// The pane's backing scale (layer `contentsScale`).
    func setBackingScale(_ scale: CGFloat)
    /// Frames replaced before display (latest-frame-wins drops).
    nonisolated var discardedFrames: Int { get }
    /// The frame on screen now, nil before the first: a hidden or discarded tab keeps it as its
    /// picture (a video layer is not drawn by `cacheDisplay`). It is the buffer the layer shows.
    var shownFrame: RemoteDecodedFrame? { get }
}

extension RemoteFramePresenter {
    /// A presenter that calls `onFrameShown` for every frame needs no arm.
    public func armFrameShown() {}
}

public struct RemoteFramePresenters {
    public nonisolated init() {}
    /// The presenter for `kind`. A and B fall back to C where Metal is missing.
    public func make(_ kind: RemotePresenterKind) -> any RemoteFramePresenter {
        switch kind {
        case .layerContents: return LayerContentsPresenter() ?? SampleBufferPresenter()
        case .metal: return MetalFramePresenter() ?? SampleBufferPresenter()
        case .sampleBuffer: return SampleBufferPresenter()
        }
    }

    /// Whether presenters A and B draw pixel buffers of `pixelFormat` (a phone's live screen checks
    /// its simulator's surface before it streams).
    package nonisolated func draws(pixelFormat: OSType) -> Bool {
        MetalYUVRenderer.draws(pixelFormat: pixelFormat)
    }
}
