public import CmuxNextRemoteView
public import CoreGraphics

#if DEBUG
/// A popup surface message from the host (`rb.surface.*`).
public nonisolated enum RbSurfaceMessage: Sendable, Equatable {
    case show(surface: UInt32, stream: UInt16, kind: String, anchor: CGRect, pixelWidth: Int, pixelHeight: Int)
    case update(surface: UInt32, anchor: CGRect, pixelWidth: Int, pixelHeight: Int)
    case hide(surface: UInt32)

    public init?(_ body: RemoteRdJSON) {
        return nil
    }
}
#endif
