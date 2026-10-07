public import AppKit
public import CmuxNextRemoteView

#if DEBUG
/// The popup surfaces of one remote tab.
@MainActor
public final class RemoteBrowserSurfaces {
    public init(
        page: RemoteBrowserContentView, source: @escaping @MainActor (UInt16) -> any RemoteViewStreamSource,
        send: @escaping @MainActor (RemoteRdJSON, Bool) -> Void
    ) {}

    public var surfaceIDs: [UInt32] { [] }

    public func apply(_ message: RbSurfaceMessage) {}

    public func closeAll() {}

    package func view(of surface: UInt32) -> RemoteBrowserContentView? { nil }

    public func sendPointer(_ event: NSEvent, at point: CGPoint, surface: UInt32) {}
}
#endif
