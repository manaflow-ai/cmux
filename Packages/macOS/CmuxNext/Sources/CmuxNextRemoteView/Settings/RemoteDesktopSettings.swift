import Foundation

/// A preset of the quality ladder (section 8).
public nonisolated enum RemoteQualityPreset: String, Sendable, Hashable, CaseIterable, Codable {
    case auto, sharpText, smoothMotion, lowBandwidth
}

/// The `remoteDesktop.*` keys of cmux.json the viewer reads (section 16).
/// Defaults are documented in this module's README; a test keeps the two
/// equal. Host-side keys (`remoteDesktop.host.*`, `refineAfterMs`) and the
/// relay caps (team policy) are read by the host and the engine, not here.
public nonisolated struct RemoteDesktopSettings: Sendable, Hashable {
    public enum Codec: String, Sendable, Hashable, CaseIterable { case auto, h264, hevc, av1 }
    public enum Resolution: String, Sendable, Hashable, CaseIterable { case matchPane, hostNative }
    public enum Clipboard: String, Sendable, Hashable, CaseIterable { case ownDevicesOnly, always, never }

    public var quality: RemoteQualityPreset = .auto
    /// nil = auto (the viewer display's refresh rate).
    public var maxFps: Int?
    /// nil = auto (congestion control decides, hard cap 80 Mbit/s).
    public var maxBitrateMbps: Double?
    public var codec: Codec = .auto
    public var resolution: Resolution = .matchPane
    public var keyboardMode: RemoteKeyboardMode = .auto
    public var sendSystemShortcuts = false
    public var clipboard: Clipboard = .ownDevicesOnly
    public var audio = false
    /// Above this RTT the pane is view only until "Control Anyway".
    public var interactiveMaxRttMs = 80
    public var showPathBadge = true

    public init() {}
}
