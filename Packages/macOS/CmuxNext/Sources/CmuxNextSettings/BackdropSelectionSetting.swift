public import Foundation
public import CmuxNextAppearance

/// Persists the selected background: bundled art, a macOS system wallpaper (`system:<path>`), the
/// person's own image (`file:<path>`), the desktop picture (`desktop`), the paintings shuffled
/// (`daily`), the pictures of a folder shuffled (`folder:<absolute path>`), or `none`. Unset is
/// ``defaultSelection``. A shuffle turns as often as `appearance.backgroundRotation` says.
public struct BackdropSelectionSetting: Sendable {
    /// The shared Settings, CLI and cmux.json path.
    public let configPath = ["appearance", "background"]

    /// Shuffle Paintings: the art set's work of the period (``BackdropArt/shuffled(on:every:calendar:)``).
    /// The id keeps its first name, from when it turned only daily.
    public static let dailyID = "daily"
    /// Shuffle a folder: `folder:<absolute path>` turns through the pictures in it.
    public static let folderPrefix = "folder:"
    /// How often a shuffle turns (``BackdropRotation``).
    public static let rotationPath = ["appearance", "backgroundRotation"]

    /// Creates the setting parser.
    public init() {}

    /// The shuffle `root` asks for, with how often it turns; nil for a fixed background.
    public static func shuffle(_ root: JSONValue) -> BackdropShuffle? {
        guard let raw = root.value(at: ["appearance", "background"])?.stringValue else { return nil }
        let rotation = root.value(at: rotationPath)?.stringValue.flatMap(BackdropRotation.init(rawValue:)) ?? .defaultRotation
        if raw == dailyID { return BackdropShuffle(source: .paintings, rotation: rotation) }
        return folderPath(raw).map { BackdropShuffle(source: .folder($0), rotation: rotation) }
    }

    /// Whether a stored background value turns on its own (`daily` or `folder:`).
    public static func shuffles(_ raw: String) -> Bool { raw == dailyID || folderPath(raw) != nil }

    /// A workspace's own background value as a shuffle, which turns daily; nil for a fixed one.
    public static func workspaceShuffle(_ raw: String) -> BackdropShuffle? {
        if raw == dailyID { return BackdropShuffle(source: .paintings, rotation: .daily) }
        return folderPath(raw).map { BackdropShuffle(source: .folder($0), rotation: .daily) }
    }

    /// The absolute path of a `folder:` value; nil for any other value or a relative path.
    static func folderPath(_ raw: String) -> String? {
        guard raw.hasPrefix(folderPrefix) else { return nil }
        let path = String(raw.dropFirst(folderPrefix.count))
        return path.hasPrefix("/") && path.count > 1 ? path : nil
    }

    /// Whether a persisted value is a valid backdrop selection. This is shared
    /// by the snapshot parser, Settings writes and the exported schema's
    /// domain marker so all entry points accept the same values.
    static func accepts(_ value: JSONValue) -> Bool {
        guard let raw = value.stringValue else { return false }
        return raw == "none" || raw == dailyID || folderPath(raw) != nil || BackdropSelection(id: raw) != nil
    }

    /// Portable examples used by schema export and conformance tests. System
    /// paths are a domain rather than a fixed enum because each macOS install
    /// publishes a different wallpaper set.
    static var acceptedSamples: [JSONValue] {
        [.string("none"), .string(dailyID), .string(BackdropSelection.desktopID)] + BackdropArt.allCases.map { .string($0.rawValue) } +
            [.string("system:/System/Library/Desktop Pictures/Solid Colors/Blue.heic"), .string("file:/Users/Shared/Harbor.png"),
             .string("folder:/Users/Shared/Wallpapers")]
    }

    static var refusedSamples: [JSONValue] {
        [.string("system:relative/path.heic"), .string("system:"), .string("file:relative.png"), .string("file:"), .string("folder:relative"),
         .string("folder:"), .string("__not_a_backdrop__"), .number(1), .bool(true)]
    }

    /// The background when neither key is set, or the set one is invalid: off. Art is opt-in
    /// (cx-t2x); turning it on by default is this one line (for example `.art(.degasHalevy)`).
    public nonisolated static let defaultSelection: BackdropSelection? = nil

    /// ``defaultSelection``'s bundled art, if it is art.
    public nonisolated static var defaultArt: BackdropArt? {
        if case .art(let art) = defaultSelection { return art }
        return nil
    }

    /// Parses the new key and accepts the legacy bundled-art key.
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> BackdropSelection? {
        if let value = root.value(at: configPath) {
            guard let raw = value.stringValue else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.background",
                                                      message: "expected none, daily, desktop, bundled art, folder:<absolute path>, or an absolute system wallpaper or image path"))
                return Self.defaultSelection
            }
            if raw == "none" { return nil }
            if BackdropArt.removedIDs.contains(raw) { return Self.defaultSelection }
            // A shuffle shows its picture of now; the app's timer turns it (`TerminalThemeSetting`).
            if let shuffle = Self.shuffle(root) { return shuffle.pick(on: Date(), calendar: .current) }
            guard let selection = BackdropSelection(id: raw) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.background",
                                                      message: "expected none, daily, desktop, bundled art, folder:<absolute path>, or an absolute system wallpaper or image path"))
                return Self.defaultSelection
            }
            return selection
        }
        guard let legacy = root.value(at: BackdropArtSetting().configPath) else { return Self.defaultSelection }
        if let raw = legacy.stringValue, BackdropArt.removedIDs.contains(raw) { return Self.defaultSelection }
        return BackdropArtSetting().parse(root, diagnostics: &diagnostics).map(BackdropSelection.art)
    }
}

/// A background that turns on its own (``BackdropSelectionSetting/shuffle(_:)``): what it turns
/// through and how often.
public struct BackdropShuffle: Equatable, Sendable {
    /// What a shuffle turns through.
    public enum Source: Equatable, Sendable {
        /// The paintings (``BackdropArt/dailyRotation``).
        case paintings
        /// The pictures directly in the folder at this absolute path, by name.
        case folder(String)
    }

    public let source: Source
    public let rotation: BackdropRotation

    public init(source: Source, rotation: BackdropRotation) {
        self.source = source
        self.rotation = rotation
    }

    /// The picture that shows at `date`, and how long until the next turn (a second past it).
    public func turn(at date: Date, calendar: Calendar) -> (picture: BackdropSelection?, wait: TimeInterval) {
        (pick(on: date, calendar: calendar), max(1, rotation.nextTurn(after: date, calendar: calendar).timeIntervalSince(date) + 1))
    }

    /// The picture that shows at `date`; nil for a folder with no pictures.
    public func pick(on date: Date, calendar: Calendar, fileManager: FileManager = .default) -> BackdropSelection? {
        switch source {
        case .paintings:
            return .art(BackdropArt.shuffled(on: date, every: rotation, calendar: calendar))
        case .folder(let path):
            // By name, so a picture keeps its turn when others are added.
            let pictures = BackdropUserImages(folder: URL(fileURLWithPath: path, isDirectory: true)).list(fileManager: fileManager)
                .sorted { $0.id < $1.id }
            return rotation.index(count: pictures.count, on: date, calendar: calendar).map { pictures[$0] }
        }
    }
}
