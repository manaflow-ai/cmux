import CmuxNextDesign

/// Persists the selected background: bundled art, a macOS system wallpaper, the desktop picture
/// (`desktop`), or `none`. Unset is the default figure drawing (``BackdropArt/defaultSelection``).
public struct BackdropSelectionSetting: Sendable {
    /// The shared Settings, CLI and cmux.json path.
    public let configPath = ["appearance", "background"]

    /// Creates the setting parser.
    public init() {}

    /// Whether a persisted value is a valid backdrop selection. This is shared
    /// by the snapshot parser, Settings writes and the exported schema's
    /// domain marker so all entry points accept the same values.
    static func accepts(_ value: JSONValue) -> Bool {
        guard let raw = value.stringValue else { return false }
        return raw == "none" || BackdropSelection(id: raw) != nil
    }

    /// Portable examples used by schema export and conformance tests. System
    /// paths are a domain rather than a fixed enum because each macOS install
    /// publishes a different wallpaper set.
    static var acceptedSamples: [JSONValue] {
        [.string("none"), .string(BackdropSelection.desktopID)] + BackdropArt.allCases.map { .string($0.rawValue) } +
            [.string("system:/System/Library/Desktop Pictures/Solid Colors/Blue.heic")]
    }

    static var refusedSamples: [JSONValue] {
        [.string("system:relative/path.heic"), .string("system:"), .string("__not_a_backdrop__"), .number(1), .bool(true)]
    }

    /// The selection when neither key is set, or the set one is invalid.
    static let fallback = BackdropSelection.art(BackdropArt.defaultSelection)

    /// Parses the new key and accepts the legacy bundled-art key.
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> BackdropSelection? {
        if let value = root.value(at: configPath) {
            guard let raw = value.stringValue else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.background",
                                                      message: "expected none, desktop, bundled art or an absolute system wallpaper path"))
                return Self.fallback
            }
            if raw == "none" { return nil }
            guard let selection = BackdropSelection(id: raw) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.background",
                                                      message: "expected none, desktop, bundled art or an absolute system wallpaper path"))
                return Self.fallback
            }
            return selection
        }
        guard root.value(at: BackdropArtSetting().configPath) != nil else { return Self.fallback }
        return BackdropArtSetting().parse(root, diagnostics: &diagnostics).map(BackdropSelection.art)
    }
}
