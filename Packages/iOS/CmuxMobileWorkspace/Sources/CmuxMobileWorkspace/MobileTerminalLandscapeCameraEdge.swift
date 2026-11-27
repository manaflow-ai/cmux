import Foundation

/// Which edge the device camera notch sits on while in landscape, used to bias
/// terminal content insets away from it.
public enum MobileTerminalLandscapeCameraEdge: Equatable, Sendable {
    /// The camera is on the leading edge.
    case leading
    /// The camera is on the trailing edge.
    case trailing
    /// There is no camera edge to protect.
    case none
}
