import Foundation

/// A normalized workspace move and the indicator that previews it.
public struct MobileWorkspaceDropTarget: Equatable, Sendable {
    /// The normalized or identity-preserving Mac-facing move intent.
    public let intent: MobileWorkspaceMoveIntent
    /// The indicator snapped to the normalized landing position.
    public let indicator: MobileWorkspaceDropIndicator
    /// Whether applying the proposed landing would preserve the current order.
    public let isNoOp: Bool

    /// Creates a resolved drop target.
    /// - Parameters:
    ///   - intent: The effective move intent, including identity landings.
    ///   - indicator: The visual preview of the normalized landing.
    ///   - isNoOp: Whether the landing preserves the current order.
    public init(
        intent: MobileWorkspaceMoveIntent,
        indicator: MobileWorkspaceDropIndicator,
        isNoOp: Bool
    ) {
        self.intent = intent
        self.indicator = indicator
        self.isNoOp = isNoOp
    }
}
