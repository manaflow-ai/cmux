public import AppKit

/// How decoded frames reach the screen. The remote desktop pane uses Metal (B);
/// the remote browser pane and page sessions use layer contents (A), which is
/// also B's fallback where Metal is missing.
public nonisolated enum RemotePresenterKind: String, Sendable, CaseIterable {
    /// A: `CALayer.contents` = the decoded IOSurface. Zero copy; the window
    /// server converts color.
    case layerContents
    /// B: `CAMetalLayer` with two drawables, a YUV shader, latest frame wins.
    case metal
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
        }
    }
}
