import Foundation
public import CmuxNextDesign

/// Persists the selected background: bundled art, a macOS system wallpaper (`system:<path>`), the
/// person's own image (`file:<path>`), the desktop picture (`desktop`), one work of the art set a
/// day (`daily`), or `none`. Unset is ``defaultSelection``.
public struct BackdropSelectionSetting: Sendable {
    /// The shared Settings, CLI and cmux.json path.
    public let configPath = ["appearance", "background"]

    /// Shuffle Daily: the art set's work of the day (``BackdropArt/daily(on:calendar:)``).
    public static let dailyID = "daily"

    /// Creates the setting parser.
    public init() {}

    /// Whether `root` asks for Shuffle Daily, so the window turns to the next work at midnight.
    public static func shufflesDaily(_ root: JSONValue) -> Bool {
        root.value(at: ["appearance", "background"])?.stringValue == dailyID
    }

    /// Whether a persisted value is a valid backdrop selection. This is shared
    /// by the snapshot parser, Settings writes and the exported schema's
    /// domain marker so all entry points accept the same values.
    static func accepts(_ value: JSONValue) -> Bool {
        guard let raw = value.stringValue else { return false }
        return raw == "none" || raw == dailyID || BackdropSelection(id: raw) != nil
    }

    /// Portable examples used by schema export and conformance tests. System
    /// paths are a domain rather than a fixed enum because each macOS install
    /// publishes a different wallpaper set.
    static var acceptedSamples: [JSONValue] {
        [.string("none"), .string(dailyID), .string(BackdropSelection.desktopID)] + BackdropArt.allCases.map { .string($0.rawValue) } +
            [.string("system:/System/Library/Desktop Pictures/Solid Colors/Blue.heic"), .string("file:/Users/Shared/Harbor.png")]
    }

    static var refusedSamples: [JSONValue] {
        [.string("system:relative/path.heic"), .string("system:"), .string("file:relative.png"), .string("file:"), .string("__not_a_backdrop__"), .number(1), .bool(true)]
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
                                                      message: "expected none, daily, desktop, bundled art, or an absolute system wallpaper or image path"))
                return Self.defaultSelection
            }
            if raw == "none" { return nil }
            if raw == Self.dailyID { return .art(.daily(on: Date())) }
            guard let selection = BackdropSelection(id: raw) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.background",
                                                      message: "expected none, daily, desktop, bundled art, or an absolute system wallpaper or image path"))
                return Self.defaultSelection
            }
            return selection
        }
        guard root.value(at: BackdropArtSetting().configPath) != nil else { return Self.defaultSelection }
        return BackdropArtSetting().parse(root, diagnostics: &diagnostics).map(BackdropSelection.art)
    }
}
