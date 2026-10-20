import CmuxNextFileGrid

/// A third-party screenshot or screen recording app whose save folders the
/// Screenshots pane finds by itself.
///
/// Each tool says where it keeps its setting (a preferences domain and key,
/// an ini or JSON file) and the folders it always uses (CleanShot X's
/// capture history, Snagit's autosave, Kap's default). A folder shows only
/// when it exists on this Mac.
public nonisolated enum ScreenshotTool: String, Sendable, CaseIterable, Hashable {
    case cleanShotX
    case shottr
    case xnapper
    case snagit
    case monosnap
    case skitch
    case flameshot
    case kap
    case cap
    case quickTime

    /// The app's name (a brand, the same in every language).
    public var displayName: String {
        switch self {
        case .cleanShotX: "CleanShot X"
        case .shottr: "Shottr"
        case .xnapper: "Xnapper"
        case .snagit: "Snagit"
        case .monosnap: "Monosnap"
        case .skitch: "Skitch"
        case .flameshot: "Flameshot"
        case .kap: "Kap"
        case .cap: "Cap"
        case .quickTime: "QuickTime Player"
        }
    }

    /// Preferences domains that may hold the app's save folder (also read from the app's sandbox
    /// container when it has one).
    var preferenceDomains: [String] {
        switch self {
        case .cleanShotX: ["pl.maketheweb.cleanshotx", "pl.maketheweb.cleanshotx-setapp"]
        case .shottr: ["cc.ffitch.shottr"]
        case .xnapper: ["com.xnapper.Xnapper", "com.xnapper.xnapper"]
        case .snagit: ["com.TechSmith.Snagit2025", "com.TechSmith.Snagit2024", "com.TechSmith.Snagit2023", "com.TechSmith.Snagit2022",
                       "com.TechSmith.Snagit2021", "com.TechSmith.Snagit2020", "com.TechSmith.Snagit"]
        case .monosnap: ["com.monosnap.monosnap"]
        case .skitch: ["com.skitch.skitch"]
        case .flameshot: ["org.flameshot.flameshot"]
        case .kap: ["com.wulkano.kap"]
        case .cap: ["so.cap.desktop"]
        case .quickTime: []
        }
    }

    /// Exact keys of the save folder, checked before the name heuristic
    /// (``ScreenshotSourceDetector/looksLikeFolderKey(_:)``).
    var folderKeys: [String] {
        switch self {
        case .cleanShotX: ["exportPath"]
        default: []
        }
    }

    /// A settings file that names the save folder: its `~/`-relative path and the key.
    var settingsFile: (path: String, key: String, format: ScreenshotSettingsFileFormat)? {
        switch self {
        case .flameshot: (".config/flameshot/flameshot.ini", "savePath", .ini)
        case .kap: ("Library/Application Support/Kap/config.json", "kapturesDir", .json)
        default: nil
        }
    }

    /// Which files the tool's save folder holds.
    var rule: FileGridScanRule {
        switch self {
        case .kap, .cap: FileGridScanRule(kinds: [.image, .video])
        case .quickTime: FileGridScanRule(kinds: [.video], namePrefixes: Self.recordingPrefixes)
        case .snagit: FileGridScanRule(extraImageExtensions: ["snagx"])
        default: FileGridScanRule()
        }
    }

    /// Folders the tool always uses, `~/`-relative, with their rule; `history` marks a capture
    /// history (every capture, saved or only copied).
    var fixedFolders: [(path: String, rule: FileGridScanRule, history: Bool)] {
        switch self {
        case .cleanShotX:
            [("Library/Application Support/CleanShot/media", FileGridScanRule(depth: 1, folderPrefix: "media_"), true)]
        case .snagit:
            [("Library/Group Containers/7TQL462TU8.com.techsmith.snagit/Snagit/Autosave", FileGridScanRule(extraImageExtensions: ["snagx"], depth: 1), true)]
        case .monosnap: [("Pictures/Monosnap", FileGridScanRule(), false)]
        case .kap: [("Movies/Kaptures", FileGridScanRule(kinds: [.image, .video]), false)]
        case .cap: [("Library/Application Support/so.cap.desktop/recordings", FileGridScanRule(kinds: [.video], depth: 3), true)]
        case .quickTime: [("Movies", rule, false)]
        default: []
        }
    }

    /// The names macOS gives screen recordings (English, then the most common system languages).
    static let recordingPrefixes = ["Screen Recording", "Bildschirmaufnahme", "Enregistrement de l’écran", "Grabación de pantalla",
                                    "Registrazione schermo", "画面収録", "屏幕录制", "螢幕錄影", "화면 기록"]
}
