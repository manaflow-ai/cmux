import Foundation

/// SECURITY: when a dialog's click-only buttons (``CmuxDialogButton/clickOnly``, a Credential Vault
/// Allow) take a press: not before the card has been on screen for ``delay`` since it showed or showed
/// again, so a click aimed at what was there before never answers it (Chrome's
/// `InputEventActivationProtector`). Times are system uptime (`ProcessInfo.systemUptime`).
public nonisolated struct CmuxDialogClickOnlyArm: Equatable, Sendable {
    /// How long after the card shows a click-only button takes no press.
    public static let delay: TimeInterval = 0.5

    /// When the card last came on screen; nil while it is not drawn.
    public private(set) var from: TimeInterval?

    public init() {}

    /// The card is drawn or shown again at `uptime`: presses wait ``delay`` from now.
    public mutating func rearm(at uptime: TimeInterval) {
        from = uptime
    }

    /// Whether a press at `uptime` counts: the card has been on screen for ``delay``.
    public func takes(at uptime: TimeInterval) -> Bool {
        guard let from else { return false }
        return uptime - from >= Self.delay
    }
}
