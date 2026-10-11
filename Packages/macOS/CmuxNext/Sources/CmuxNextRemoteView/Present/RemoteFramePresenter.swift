public import AppKit
public import CmuxNextDesign

/// Presenter prototypes (`remoteDesktop.debug.presenter`, DEV and NIGHTLY
/// Debug Settings; section 7). Lawrence picks after the lit-display bench.
public nonisolated enum RemotePresenterKind: String, Sendable, CaseIterable, TunableChoice {
    /// A: `CALayer.contents` = the decoded IOSurface. Zero copy; the window
    /// server converts color.
    case layerContents
    /// B: `CAMetalLayer` with two drawables, a YUV shader, latest frame wins.
    case metal
    /// C: `AVSampleBufferDisplayLayer` with display-immediately samples.
    case sampleBuffer

    public var tunableTitle: String {
        switch self {
        case .layerContents: "A: Layer contents (IOSurface)"
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
    nonisolated func present(_ frame: RemoteDecodedFrame)
    /// The pane's backing scale (layer `contentsScale`).
    func setBackingScale(_ scale: CGFloat)
    /// Frames replaced before display (latest-frame-wins drops).
    nonisolated var discardedFrames: Int { get }
}

public struct RemoteFramePresenters {
    public nonisolated init() {}
    /// The presenter for `kind`. B falls back to A where Metal is missing.
    public func make(_ kind: RemotePresenterKind) -> any RemoteFramePresenter {
        switch kind {
        case .layerContents: return LayerContentsPresenter()
        case .metal: return MetalFramePresenter() ?? LayerContentsPresenter()
        case .sampleBuffer: return SampleBufferPresenter()
        }
    }
}
