public import CmuxRemoteDesktop

/// The desktops this Mac can show a phone (c3-rd.md 1): its displays and
/// windows through ScreenCaptureKit, and VNC servers it can reach.
/// `describe` reads metadata only; nothing is captured or dialed before the
/// person at the Mac consents and the session calls `open`.
public protocol RemoteDesktopSources: Sendable {
    func displays() async -> [DesktopDisplay]
    func windows() async -> [DesktopWindow]
    /// The target's size and name, without capturing. Throws
    /// `RemoteDesktopSourceError` (`displayNotFound`, `windowNotFound`).
    func describe(_ target: DesktopTarget) async throws -> DesktopTargetInfo
    /// Starts capture (or dials the VNC server). Throws `RemoteDesktopSourceError`.
    func open(_ request: RemoteDesktopOpenRequest) async throws -> any RemoteDesktopTarget
}
