public import AppKit
import GhosttyNextKit

/// The bell keys of a Ghostty config (`bell-features`, `bell-audio-path`,
/// `bell-audio-volume`) and what a BEL does under them, as in Ghostty.app's
/// `ghosttyBellDidRing`: `system` beeps, `audio` plays the file at its
/// volume, `attention` asks for the user's attention while the app is not
/// active. `title` and `border` are drawn by the tab chrome
/// (`TerminalSurfaceModel.bellCount`).
public nonisolated struct GhosttyBellSettings: Equatable, Sendable {
    public struct Features: OptionSet, Sendable, Equatable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let system = Features(rawValue: 1 << 0)
        public static let audio = Features(rawValue: 1 << 1)
        public static let attention = Features(rawValue: 1 << 2)
        public static let title = Features(rawValue: 1 << 3)
        public static let border = Features(rawValue: 1 << 4)
        /// Ghostty's default.
        public static let ghosttyDefault: Features = [.attention, .title]
    }

    public enum Effect: Equatable, Sendable {
        case systemBeep
        case playSound(path: String, volume: Double)
        case requestAttention
    }

    public var features: Features
    public var audioPath: String?
    public var volume: Double

    public init(features: Features = .ghosttyDefault, audioPath: String? = nil, volume: Double = 0.5) {
        self.features = features
        self.audioPath = audioPath
        self.volume = volume
    }

    /// The bell keys of `config`, a live handle the caller holds for the call.
    init(config: ghostty_config_t) {
        var bits: UInt32 = Features.ghosttyDefault.rawValue
        // SAFETY: the caller's live config; bell-features is a uint32 bit set.
        _ = unsafe GhosttyRuntime.configGet(config, &bits, key: "bell-features")
        var path = ghostty_config_path_s()
        // SAFETY: the caller's live config; bell-audio-path is a ghostty_config_path_s.
        let hasPath = unsafe GhosttyRuntime.configGet(config, &path, key: "bell-audio-path")
        // SAFETY: the path is NUL-terminated and owned by the live config; String(cString:) copies it.
        let audioPath = unsafe hasPath ? path.path.map { unsafe String(cString: $0) } : nil
        var volume = 0.5
        // SAFETY: the caller's live config; bell-audio-volume is a C double.
        _ = unsafe GhosttyRuntime.configGet(config, &volume, key: "bell-audio-volume")
        self.init(features: Features(rawValue: bits), audioPath: audioPath?.isEmpty == false ? audioPath : nil,
                  volume: volume)
    }

    /// The settings of a config made of `text` (Ghostty config lines), for tests.
    init(configText text: String) {
        // SAFETY: withScratchConfig's handle is live for each closure's call and stays in it.
        self = unsafe GhosttyRuntime.withScratchConfig(
            load: { unsafe GhosttyRuntime.loadConfigLine(text, into: $0, source: "test") },
            read: { unsafe GhosttyBellSettings(config: $0) }
        ) ?? GhosttyBellSettings()
    }

    /// What one BEL does.
    public func effects(appIsActive: Bool) -> [Effect] {
        var effects: [Effect] = []
        if features.contains(.system) { effects.append(.systemBeep) }
        if features.contains(.audio), let audioPath { effects.append(.playSound(path: audioPath, volume: volume)) }
        if features.contains(.attention), !appIsActive { effects.append(.requestAttention) }
        return effects
    }

    /// Performs the effects of one BEL.
    @MainActor public func ring() {
        for effect in effects(appIsActive: NSApp?.isActive ?? true) {
            switch effect {
            case .systemBeep:
                NSSound.beep()
            case .playSound(let path, let volume):
                guard let sound = NSSound(contentsOfFile: path, byReference: false) else { continue }
                sound.volume = Float(volume)
                sound.play()
            case .requestAttention:
                NSApp?.requestUserAttention(.informationalRequest)
            }
        }
    }
}

extension GhosttyRuntime {
    /// The bell keys of the applied config; Ghostty's defaults when none loaded.
    public var bellSettings: GhosttyBellSettings {
        guard let config else { return GhosttyBellSettings() }
        // SAFETY: `config` is the live applied config (GhosttyRuntime's note), held for this call.
        return unsafe GhosttyBellSettings(config: config)
    }
}
