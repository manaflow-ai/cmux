/// The non-dismissable host indicator (menu bar item and screen pill,
/// "Viewed by" / "Controlled by" with Stop). One `begin` per live session.
public protocol RemoteDesktopIndicator: Sendable {
    func begin(_ session: RemoteDesktopIndicatorSession) async -> any RemoteDesktopIndicatorHandle
}
