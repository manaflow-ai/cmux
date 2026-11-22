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

    /// Every key with its default as the README table writes it.
    public static let documentedKeys: [String] = [
        "remoteDesktop.quality", "remoteDesktop.maxFps", "remoteDesktop.maxBitrateMbps",
        "remoteDesktop.codec", "remoteDesktop.resolution", "remoteDesktop.keyboard.mode",
        "remoteDesktop.keyboard.sendSystemShortcuts", "remoteDesktop.clipboard", "remoteDesktop.audio",
        "remoteDesktop.interactiveMaxRttMs", "remoteDesktop.showPathBadge",
    ]

    /// `key` -> value rendered like the README (`auto`, `80`, `false`).
    public var documentedValues: [String: String] {
        [
            "remoteDesktop.quality": quality.rawValue,
            "remoteDesktop.maxFps": maxFps.map(String.init) ?? "auto",
            "remoteDesktop.maxBitrateMbps": maxBitrateMbps.map { String(format: "%g", $0) } ?? "auto",
            "remoteDesktop.codec": codec.rawValue,
            "remoteDesktop.resolution": resolution.rawValue,
            "remoteDesktop.keyboard.mode": keyboardMode.rawValue,
            "remoteDesktop.keyboard.sendSystemShortcuts": String(sendSystemShortcuts),
            "remoteDesktop.clipboard": clipboard.rawValue,
            "remoteDesktop.audio": String(audio),
            "remoteDesktop.interactiveMaxRttMs": String(interactiveMaxRttMs),
            "remoteDesktop.showPathBadge": String(showPathBadge),
        ]
    }
}
