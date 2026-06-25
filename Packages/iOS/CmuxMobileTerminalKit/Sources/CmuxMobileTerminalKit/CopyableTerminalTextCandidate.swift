/// Inputs describing a registered surface view for the "View as Text"
/// eligibility decision.
///
/// The values mirror the runtime fields read off `GhosttySurfaceView`
/// (`hostSurfaceID`, `surface != nil`, dismantled state, `window != nil`,
/// `isHidden`, `alpha`)
/// as plain values so the rule is testable without a UIKit view.
public struct CopyableTerminalTextCandidate: Equatable, Sendable {
    /// The shell-level surface id stamped on the mounted terminal view.
    public let hostSurfaceID: String?
    /// Whether the view still owns a live libghostty surface pointer.
    public let hasSurface: Bool
    /// Whether SwiftUI has dismantled this surface view.
    public let isDismantled: Bool
    /// Whether the view is currently attached to a window.
    public let hasWindow: Bool
    /// Whether UIKit marks the view hidden.
    public let isHidden: Bool
    /// The view alpha used to exclude fully transparent transition states.
    public let alpha: Double

    /// Creates a candidate snapshot from the runtime surface-view fields.
    public init(
        hostSurfaceID: String?,
        hasSurface: Bool,
        isDismantled: Bool = false,
        hasWindow: Bool,
        isHidden: Bool,
        alpha: Double
    ) {
        self.hostSurfaceID = hostSurfaceID
        self.hasSurface = hasSurface
        self.isDismantled = isDismantled
        self.hasWindow = hasWindow
        self.isHidden = isHidden
        self.alpha = alpha
    }
}
