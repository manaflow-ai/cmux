public import CmuxNextDesign
public import Foundation

/// `appearance.fontSmoothing` in cmux.json: `auto` (the default), `antialiased` or `subpixel`
/// (``FontSmoothing``), for native and web text.
///
/// Web pages follow a change at once (``WebTheme``). Native text follows it at the next launch:
/// AppKit fixes its text weight at its first draw (``ProcessFontSmoothing``), and part of AppKit
/// reads the saved value as it starts, so `main` calls ``applyBeforeLaunch(fileURL:managed:defaults:)``
/// before `NSApplication` exists.
public nonisolated struct FontSmoothingSetting {
    public nonisolated init() {}
    // The path and default are generated from schemas/settings/source/appearance.json.

    /// A missing key is ``fallback`` with no diagnostic; a bad value is ``fallback`` plus a diagnostic.
    static func parse(_ root: JSONValue) -> (FontSmoothing, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        // The first release's name for auto.
        if value.stringValue == "system" { return (.auto, nil) }
        guard let text = value.stringValue, let mode = FontSmoothing(rawValue: text) else {
            let choices = FontSmoothing.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                 message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }

    /// Writes the settings file's `appearance.fontSmoothing` (with managed values over it) to
    /// `defaults` for AppKit, before `NSApplication` starts, and returns the mode.
    ///
    /// AppKit reads a saved `AppleFontSmoothing` as it starts, before `applicationDidFinishLaunching`,
    /// so a change made while cmux was not running (the file edited by hand, or an update that
    /// changes the default) must be written here to show at this launch. A missing or unreadable
    /// file is the default, ``FontSmoothing/auto``.
    ///
    /// - Parameters:
    ///   - fileURL: the settings file (``CmuxConfigFile/defaultURL(home:environment:)``).
    ///   - managed: the managed (MDM) values, which win over the file; by default only this setting's key
    ///     (``ManagedPreferenceLocation/reader(keys:environment:)``: not the whole schema, CMUX-631).
    ///   - defaults: the app's defaults.
    /// - Returns: the mode written.
    @discardableResult
    public static func applyBeforeLaunch(fileURL: URL = CmuxConfigFile.defaultURL(),
                                         managed: (any ManagedPreferenceReader)? = nil,
                                         defaults: UserDefaults = .standard) -> FontSmoothing {
        let root = (try? JSONC.parse(CmuxConfigFile.source(at: fileURL))) ?? .object([:])
        let managed = managed ?? ManagedPreferenceLocation.reader(keys: [configPath.joined(separator: ".")])
        let mode = parse(EffectiveSettings.merge(file: root, managed: managed.read(), team: .none).root).0
        ProcessFontSmoothing.apply(mode, to: defaults)
        return mode
    }
}
