public import AppKit
public import CmuxNextRemoteView

#if DEBUG
/// One remote tab's page: owns the decode pipeline from a stream source to
/// the presenter. Session state (menus, dialogs, cursor) lives in the Rust
/// client reducer; this type only moves frames and reports sizes.
@MainActor
public final class RemoteBrowserPane {
    public let view = RemoteBrowserContentView()
    private let source: any RemoteViewStreamSource

    public init(source: any RemoteViewStreamSource, presenter: RemotePresenterKind = .layerContents) {
        self.source = source
    }

    /// Decoded frame sizes in device pixels, one value per change.
    public func frameSizes() -> AsyncStream<CGSize> {
        AsyncStream { $0.finish() }
    }

    public func start() {}
    public func stop() {}
}
#endif
