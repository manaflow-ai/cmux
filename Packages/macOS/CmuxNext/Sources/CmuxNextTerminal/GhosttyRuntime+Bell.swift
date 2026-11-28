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

    init(config: ghostty_config_t) {
        var bits: UInt32 = Features.ghosttyDefault.rawValue
        _ = Self.get(config, &bits, key: "bell-features")
        var path = ghostty_config_path_s()
        let hasPath = Self.get(config, &path, key: "bell-audio-path")
        let audioPath = hasPath ? path.path.map { String(cString: $0) } : nil
        var volume = 0.5
        _ = Self.get(config, &volume, key: "bell-audio-volume")
        self.init(features: Features(rawValue: bits), audioPath: audioPath?.isEmpty == false ? audioPath : nil,
                  volume: volume)
    }

    /// `ghostty_config_get` for one key, callable off the main actor.
    private static func get<T: BitwiseCopyable>(_ config: ghostty_config_t, _ value: inout T, key: String) -> Bool {
        withUnsafeMutablePointer(to: &value) { pointer in
            key.withCString { ghostty_config_get(config, pointer, $0, UInt(key.utf8.count)) }
        }
    }

    /// The settings of a config made of `text` (Ghostty config lines), for tests.
    init(configText text: String) {
        guard let config = ghostty_config_new() else { self.init(); return }
        defer { ghostty_config_free(config) }
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "test") }
        ghostty_config_finalize(config)
        self.init(config: config)
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
        return GhosttyBellSettings(config: config)
    }
}
